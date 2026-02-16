// supabase/functions/_shared/ioHelpers.ts

import { Errors, badRequest, getCorsHeaders } from "./constants.ts"

// Types
export interface ParsedFile {
  name: string | null
  filename: string
  content: string
}

export interface MultipartResult {
  files: ParsedFile[]
  fields: Record<string, string>
}

// Helper to handle CORS preflight OPTIONS requests
export function corsResponse(origin: string): Response {
  return new Response(null, {
    status: 204,
    headers: getCorsHeaders(origin),
  })
}

// Helper to return JSON response with CORS headers
export function json(obj: unknown, status = 200, origin?: string): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      ...getCorsHeaders(origin),
    },
  })
}

// Extract boundary from content-type header, returns null if not found
export function getBoundary(contentType: string): string | null {
  return contentType.match(/boundary=([^;]+)/)?.[1] ?? null
}

// Parse multipart/form-data - throws Response on error
export async function parseMultipart(req: Request): Promise<MultipartResult> {
  const ct = req.headers.get("content-type") || ""
  const boundary = getBoundary(ct)
  
  if (!boundary) {
    throw badRequest(Errors.MISSING_BOUNDARY)
  }

  const buf = new Uint8Array(await req.arrayBuffer())
  const text = new TextDecoder().decode(buf)
  const sections = text.split("--" + boundary).slice(1, -1)
  const files: ParsedFile[] = []
  const fields: Record<string, string> = {}

  for (const section of sections) {
    const [rawHeaders, bodyRaw] = section.split("\r\n\r\n")
    if (!bodyRaw) continue
    const body = bodyRaw.replace(/\r\n$/, "")
    const headerLines = rawHeaders.split("\r\n").filter(Boolean)
    const headers: Record<string, string> = {}

    for (const line of headerLines) {
      const i = line.indexOf(":")
      if (i !== -1) {
        headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim()
      }
    }

    const cd = headers["content-disposition"]
    if (!cd) continue

    const name = cd.match(/name="([^"]+)"/)?.[1] ?? null
    const filename = cd.match(/filename="([^"]+)"/)?.[1] ?? null

    if (filename) {
      files.push({ name, filename, content: body })
    } else if (name) {
      fields[name] = body
    }
  }

  if (files.length === 0) {
    throw badRequest(Errors.NO_FILE)
  }

  return { files, fields }
}

// Parse CSV content - throws Response on error
export function parseCsv<T = Record<string, string>>(
  csv: string,
  requiredHeaders?: string[]
): T[] {
  const trimmed = csv.trim()
  if (!trimmed) {
    throw badRequest(Errors.EMPTY_CSV)
  }

  const lines = trimmed.split(/\r?\n/).filter((l) => l.trim().length > 0)
  if (lines.length === 0) {
    throw badRequest(Errors.EMPTY_CSV)
  }

  const header = lines[0].split(",").map((h) => h.trim())
  
  // Check required headers if specified
  if (requiredHeaders) {
    for (const required of requiredHeaders) {
      if (!header.includes(required)) {
        throw badRequest(Errors.MISSING_HEADER, { missing: required })
      }
    }
  }

  const rows = lines.slice(1).map((line) => {
    const cols = line.split(",")
    const row: Record<string, string> = {}
    header.forEach((h, i) => (row[h] = cols[i]?.trim() ?? ""))
    return row as T
  })

  if (rows.length === 0) {
    throw badRequest(Errors.NO_ROWS)
  }

  return rows
}

// Get CSV content from request (handles both multipart and raw text)
export async function getCsvFromRequest(req: Request): Promise<string> {
  const ct = req.headers.get("content-type") || ""
  
  if (ct.startsWith("multipart/form-data")) {
    const { files } = await parseMultipart(req)
    return files[0].content
  }
  
  const text = await req.text()
  if (!text.trim()) {
    throw badRequest(Errors.EMPTY_CSV)
  }
  
  return text
}

