// RSA PKCS1v1.5 chunked encryption/decryption for TBI Bank integration.
// TBI requires PKCS1v1.5 padding which crypto.subtle doesn't support for
// encryption, so we implement it with raw BigInt modular exponentiation.

// ─── PEM parsing ────────────────────────────────────────────────────────────

function pemToBytes(pem: string): Uint8Array {
  const b64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s/g, "")
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
}

// ─── ASN.1 / DER helpers ────────────────────────────────────────────────────

function readDerLength(buf: Uint8Array, offset: number): [number, number] {
  const first = buf[offset]
  if (first < 0x80) return [first, offset + 1]
  const numBytes = first & 0x7f
  let length = 0
  for (let i = 0; i < numBytes; i++) {
    length = (length << 8) | buf[offset + 1 + i]
  }
  return [length, offset + 1 + numBytes]
}

function readDerSequence(buf: Uint8Array, offset: number): [Uint8Array, number] {
  if (buf[offset] !== 0x30) throw new Error("Expected SEQUENCE tag")
  const [len, dataStart] = readDerLength(buf, offset + 1)
  return [buf.slice(dataStart, dataStart + len), dataStart + len]
}

function readDerInteger(buf: Uint8Array, offset: number): [Uint8Array, number] {
  if (buf[offset] !== 0x02) throw new Error("Expected INTEGER tag")
  const [len, dataStart] = readDerLength(buf, offset + 1)
  return [buf.slice(dataStart, dataStart + len), dataStart + len]
}

function skipDerElement(buf: Uint8Array, offset: number): number {
  const [len, dataStart] = readDerLength(buf, offset + 1)
  return dataStart + len
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  let result = 0n
  for (const b of bytes) result = (result << 8n) | BigInt(b)
  return result
}

function bigIntToBytes(n: bigint, length: number): Uint8Array {
  const result = new Uint8Array(length)
  for (let i = length - 1; i >= 0; i--) {
    result[i] = Number(n & 0xffn)
    n >>= 8n
  }
  return result
}

// ─── RSA key extraction ─────────────────────────────────────────────────────

interface RsaPublicKey {
  n: bigint
  e: bigint
  keyBytes: number
}

interface RsaPrivateKey {
  n: bigint
  d: bigint
  keyBytes: number
}

export function parsePublicKey(pem: string): RsaPublicKey {
  const der = pemToBytes(pem)
  // PKCS#8 SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { SEQUENCE { n, e } } }
  const [outer] = readDerSequence(der, 0)
  // Skip algorithmIdentifier sequence
  let offset = 0
  offset = skipDerElement(outer, offset) // skip algorithm SEQUENCE
  // BIT STRING
  if (outer[offset] !== 0x03) throw new Error("Expected BIT STRING")
  const [bsLen, bsDataStart] = readDerLength(outer, offset + 1)
  const bitString = outer.slice(bsDataStart, bsDataStart + bsLen)
  // Skip the "unused bits" byte
  const [inner] = readDerSequence(bitString, 1)
  const [nBytes, afterN] = readDerInteger(inner, 0)
  const [eBytes] = readDerInteger(inner, afterN)

  const n = bytesToBigInt(nBytes)
  const e = bytesToBigInt(eBytes)
  // Key size in bytes: strip leading zero from DER integer encoding
  const keyBytes = nBytes[0] === 0 ? nBytes.length - 1 : nBytes.length

  return { n, e, keyBytes }
}

export function parsePrivateKey(pem: string): RsaPrivateKey {
  const der = pemToBytes(pem)
  let inner: Uint8Array

  // Try PKCS#8 first (PrivateKeyInfo wrapper)
  try {
    const [outer] = readDerSequence(der, 0)
    let offset = 0
    // version INTEGER
    offset = skipDerElement(outer, offset)
    // algorithmIdentifier SEQUENCE
    offset = skipDerElement(outer, offset)
    // privateKey OCTET STRING containing RSAPrivateKey
    if (outer[offset] !== 0x04) throw new Error("not pkcs8")
    const [octetLen, octetStart] = readDerLength(outer, offset + 1)
    const pkcs1Der = outer.slice(octetStart, octetStart + octetLen)
    const [seq] = readDerSequence(pkcs1Der, 0)
    inner = seq
  } catch {
    // Try PKCS#1 RSAPrivateKey directly
    const [seq] = readDerSequence(der, 0)
    inner = seq
  }

  // RSAPrivateKey: version, n, e, d, p, q, dp, dq, qinv
  let offset = 0
  offset = skipDerElement(inner, offset) // version
  const [nBytes, afterN] = readDerInteger(inner, offset)
  offset = skipDerElement(inner, afterN) // e
  const [dBytes] = readDerInteger(inner, offset)

  const n = bytesToBigInt(nBytes)
  const d = bytesToBigInt(dBytes)
  const keyBytes = nBytes[0] === 0 ? nBytes.length - 1 : nBytes.length

  return { n, d, keyBytes }
}

// ─── Modular exponentiation ─────────────────────────────────────────────────

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n
  base = base % mod
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod
    exp >>= 1n
    base = (base * base) % mod
  }
  return result
}

// ─── PKCS1v1.5 padding ─────────────────────────────────────────────────────

function pkcs1v15Pad(message: Uint8Array, keyBytes: number): Uint8Array {
  const maxMsgLen = keyBytes - 11
  if (message.length > maxMsgLen) {
    throw new Error(`Message too long for key: ${message.length} > ${maxMsgLen}`)
  }

  const paddingLen = keyBytes - message.length - 3
  const padding = new Uint8Array(paddingLen)
  crypto.getRandomValues(padding)
  // Ensure no zero bytes in padding
  for (let i = 0; i < paddingLen; i++) {
    while (padding[i] === 0) {
      const tmp = new Uint8Array(1)
      crypto.getRandomValues(tmp)
      padding[i] = tmp[0]
    }
  }

  // 0x00 || 0x02 || padding || 0x00 || message
  const result = new Uint8Array(keyBytes)
  result[0] = 0x00
  result[1] = 0x02
  result.set(padding, 2)
  result[2 + paddingLen] = 0x00
  result.set(message, 3 + paddingLen)
  return result
}

function pkcs1v15Unpad(padded: Uint8Array): Uint8Array {
  if (padded[0] !== 0x00 || padded[1] !== 0x02) {
    throw new Error("Invalid PKCS1v1.5 padding")
  }
  // Find the 0x00 separator after padding
  let i = 2
  while (i < padded.length && padded[i] !== 0x00) i++
  if (i >= padded.length) throw new Error("Invalid PKCS1v1.5 padding: no separator")
  return padded.slice(i + 1)
}

// ─── Chunked encrypt / decrypt ──────────────────────────────────────────────

export async function rsaChunkEncrypt(plaintext: string, publicKeyPem: string): Promise<string> {
  const key = parsePublicKey(publicKeyPem)
  const data = new TextEncoder().encode(plaintext)
  const blockSize = key.keyBytes - 11 // max plaintext per chunk

  const encryptedChunks: Uint8Array[] = []
  for (let i = 0; i < data.length; i += blockSize) {
    const chunk = data.slice(i, i + blockSize)
    const padded = pkcs1v15Pad(chunk, key.keyBytes)
    const m = bytesToBigInt(padded)
    const c = modPow(m, key.e, key.n)
    encryptedChunks.push(bigIntToBytes(c, key.keyBytes))
  }

  // Concatenate all encrypted chunks
  const totalLen = encryptedChunks.reduce((s, c) => s + c.length, 0)
  const combined = new Uint8Array(totalLen)
  let offset = 0
  for (const chunk of encryptedChunks) {
    combined.set(chunk, offset)
    offset += chunk.length
  }

  return btoa(String.fromCharCode(...combined))
}

export async function rsaChunkDecrypt(ciphertext: string, privateKeyPem: string): Promise<string> {
  const key = parsePrivateKey(privateKeyPem)
  const data = Uint8Array.from(atob(ciphertext), (c) => c.charCodeAt(0))
  const blockSize = key.keyBytes // encrypted block = key size

  const decryptedChunks: Uint8Array[] = []
  for (let i = 0; i < data.length; i += blockSize) {
    const chunk = data.slice(i, i + blockSize)
    const c = bytesToBigInt(chunk)
    const m = modPow(c, key.d, key.n)
    const padded = bigIntToBytes(m, key.keyBytes)
    decryptedChunks.push(pkcs1v15Unpad(padded))
  }

  // Concatenate and decode
  const totalLen = decryptedChunks.reduce((s, c) => s + c.length, 0)
  const combined = new Uint8Array(totalLen)
  let offset = 0
  for (const chunk of decryptedChunks) {
    combined.set(chunk, offset)
    offset += chunk.length
  }

  return new TextDecoder().decode(combined)
}
