// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, forbidden, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { decrypt } from "../_shared/piiCrypto.ts"

// ─── Types (matching DB column shapes) ──────────────────────────────────────

interface Profile {
  user_id: string
  email: string
  company_id: string
  first_name: string
  last_name: string
  description: string | null
  department: string | null
  hire_date: number | null
  profile_image_path: string | null
}

interface Invite {
  id: string
  email: string
  status: string
  company_id: string
  first_name: string
  last_name: string
  description: string | null
  department: string | null
  hire_date: number | null
}

interface Company {
  name: string
  logo_image_path: string | null
  contact_email: string | null
  address_lat: number | null
  address_lon: number | null
  days_in_office: number | null
}

interface BikeBenefit {
  id: string
  benefit_status: string | null
  contract_status: string | null
  bike_id: string | null
  employee_monthly_price: number | null
  employee_full_price: number | null
  employee_contract_months: number | null
  employee_currency: string | null
  contract_approved_at: string | null
  delivered_at: string | null
}

interface Bike {
  name: string
  brand: string | null
  images: string[] | null
  weight_kg: number | null
  charge_time_hours: number | null
  range_max_km: number | null
  power_wh: number | null
}

interface Contract {
  sign_page_url: string | null
}

interface BikeOrder {
  helmet: boolean | null
  insurance: boolean | null
}

interface EmployeePii {
  national_id_encrypted: string | null
  date_of_birth_encrypted: string | null
  phone_encrypted: string | null
  home_address_encrypted: string | null
  home_lat_encrypted: string | null
  home_lon_encrypted: string | null
  salary_gross_encrypted: string | null
  nationality_iso: string | null
  country_of_domicile_iso: string | null
  id_document_type: string | null
  education_level: string | null
}

// Fields that are encrypted in the employee_pii table
const ENCRYPTED_FIELDS: (keyof EmployeePii & string)[] = [
  "national_id_encrypted",
  "date_of_birth_encrypted",
  "phone_encrypted",
  "home_address_encrypted",
  "home_lat_encrypted",
  "home_lon_encrypted",
  "salary_gross_encrypted",
]

// ─── Handler ─────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!
    const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    const db          = makeRestClient(supabaseUrl, serviceKey)

    const jwt      = requireJwt(req, origin)
    const callerId = extractUserId(jwt, origin)
    const callerRole = jwt.user_role as string | undefined

    // Determine target user — self by default, or another employee for HR
    let targetUserId = callerId

    if (req.method === "POST") {
      const body = await req.json().catch(() => ({}))
      if (body.user_id && body.user_id !== callerId) {
        // Only HR / admin can read another employee's details
        if (callerRole !== "hr" && callerRole !== "admin") {
          throw forbidden(undefined, origin)
        }
        targetUserId = body.user_id
      }
    }

    // ── 1. Load profile (required — user must be registered) ────────────────
    const profile = await db.getOne<Profile>(
      "profiles",
      `user_id=eq.${encodeURIComponent(targetUserId)}`,
      "user_id,email,company_id,first_name,last_name,description,department,hire_date,profile_image_path"
    )
    if (!profile) throw badRequest(Errors.PROFILE_NOT_FOUND, undefined, origin)

    // If HR is reading another employee, verify same company
    if (targetUserId !== callerId) {
      const callerProfile = await db.getOne<{ company_id: string }>(
        "profiles",
        `user_id=eq.${encodeURIComponent(callerId)}`,
        "company_id"
      )
      if (!callerProfile || callerProfile.company_id !== profile.company_id) {
        throw forbidden(undefined, origin)
      }
    }

    // ── 2-3. Load invite + company (independent, both needed) ───────────────
    const [invite, company] = await Promise.all([
      db.getOne<Invite>(
        "profile_invites",
        `email=eq.${encodeURIComponent(profile.email)}`,
        "id,email,status,company_id,first_name,last_name,description,department,hire_date"
      ),
      db.getOne<Company>(
        "companies",
        `id=eq.${profile.company_id}`,
        "name,logo_image_path,contact_email,address_lat,address_lon,days_in_office"
      ),
    ])

    // ── 4. Load bike benefit ────────────────────────────────────────────────
    const benefit = await db.getOne<BikeBenefit>(
      "bike_benefits",
      `user_id=eq.${encodeURIComponent(targetUserId)}`,
      "id,benefit_status,contract_status,bike_id,employee_monthly_price,employee_full_price,employee_contract_months,employee_currency,contract_approved_at,delivered_at"
    )

    // ── 5-8. Load dependent data in parallel ────────────────────────────────
    const [bike, contract, bikeOrder, piiRecord] = await Promise.all([
      benefit?.bike_id
        ? db.getOne<Bike>(
            "bikes",
            `id=eq.${benefit.bike_id}`,
            "name,brand,images,weight_kg,charge_time_hours,range_max_km,power_wh"
          )
        : null,
      benefit
        ? db.getOne<Contract>(
            "contracts",
            `bike_benefit_id=eq.${benefit.id}`,
            "sign_page_url"
          )
        : null,
      benefit
        ? db.getOne<BikeOrder>(
            "bike_orders",
            `bike_benefit_id=eq.${benefit.id}`,
            "helmet,insurance"
          )
        : null,
      db.getOne<EmployeePii>(
        "employee_pii",
        `user_id=eq.${encodeURIComponent(targetUserId)}`,
        "national_id_encrypted,date_of_birth_encrypted,phone_encrypted,home_address_encrypted,home_lat_encrypted,home_lon_encrypted,salary_gross_encrypted,nationality_iso,country_of_domicile_iso,id_document_type,education_level"
      ),
    ])

    // ── Decrypt PII fields ──────────────────────────────────────────────────
    let pii: Record<string, unknown> | null = null
    if (piiRecord) {
      // Order must match ENCRYPTED_FIELDS array above
      const [
        nationalId, dateOfBirth, phone,
        homeAddress, homeLat, homeLon, salaryGross,
      ] = await Promise.all(
        ENCRYPTED_FIELDS.map((f) => {
          const v = piiRecord[f]
          return v == null || v === "" ? null : decrypt(db, v)
        })
      )

      pii = {
        home_address:           homeAddress,
        home_lat:               homeLat  != null ? parseFloat(homeLat)  : null,
        home_lon:               homeLon  != null ? parseFloat(homeLon)  : null,
        national_id:            nationalId,
        date_of_birth:          dateOfBirth,
        phone:                  phone,
        salary_gross:           salaryGross != null ? parseFloat(salaryGross) : null,
        nationality_iso:        piiRecord.nationality_iso,
        country_of_domicile_iso: piiRecord.country_of_domicile_iso,
        id_document_type:       piiRecord.id_document_type,
        education_level:        piiRecord.education_level,
      }
    }

    // ── Build response (superset of old user_profile_detail view) ───────────
    // COALESCE logic: prefer profile values, fall back to invite values
    const response = {
      invite_id:                invite?.id ?? null,
      email:                    profile.email,
      invite_status:            invite?.status ?? null,
      company_id:               profile.company_id,
      company_name:             company?.name ?? null,
      company_contact_email:    company?.contact_email ?? null,
      logo_image_path:          company?.logo_image_path ?? null,

      user_id:                  profile.user_id,
      profile_image_path:       profile.profile_image_path ?? null,
      first_name:               profile.first_name  ?? invite?.first_name ?? null,
      last_name:                profile.last_name   ?? invite?.last_name ?? null,
      description:              profile.description  ?? invite?.description ?? null,
      department:               profile.department   ?? invite?.department ?? null,
      hire_date:                profile.hire_date    ?? invite?.hire_date ?? null,

      bike_benefit_id:          benefit?.id ?? null,
      benefit_status:           benefit?.benefit_status ?? null,
      contract_status:          benefit?.contract_status ?? null,
      bike_id:                  benefit?.bike_id ?? null,
      employee_monthly_price:   benefit?.employee_monthly_price ?? null,
      employee_full_price:      benefit?.employee_full_price ?? null,
      employee_contract_months: benefit?.employee_contract_months ?? null,
      employee_currency:        benefit?.employee_currency ?? null,
      contract_approved_at:     benefit?.contract_approved_at ?? null,
      delivered_at:             benefit?.delivered_at ?? null,

      bike_name:                bike?.name ?? null,
      bike_brand:               bike?.brand ?? null,
      bike_images:              bike?.images ?? null,
      weight_kg:                bike?.weight_kg ?? null,
      charge_time_hours:        bike?.charge_time_hours ?? null,
      range_max_km:             bike?.range_max_km ?? null,
      power_wh:                 bike?.power_wh ?? null,

      sign_page_url:            contract?.sign_page_url ?? null,
      helmet:                   bikeOrder?.helmet ?? null,
      insurance:                bikeOrder?.insurance ?? null,

      company_address_lat:      company?.address_lat ?? null,
      company_address_lon:      company?.address_lon ?? null,
      days_in_office:           company?.days_in_office ?? null,

      pii,
    }

    return json(response, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    throw e
  }
})
