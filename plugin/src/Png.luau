--!strict
--[[
	PNG and base64, written out by hand.

	Studio gives a screenshot as an EditableImage, which hands over raw RGBA
	bytes and nothing else. There is no encoder anywhere in the engine's API, and
	no base64 either -- `HttpService` has JSONEncode and nothing adjacent -- so
	getting a picture from Studio to an agent means producing both here.

	The compression is deliberately none at all. Deflate's stored mode wraps the
	bytes in block headers and changes nothing else, which is legal zlib and a
	valid PNG; a real compressor would take far longer to write and run, and the
	image is downscaled before it reaches this point, so the saving would be on
	something already small. Correctness is worth more than bytes here.
]]

local Png = {}

-- Standard CRC-32, built once. The per-byte loop is 8 shifts; a 256-entry table
-- turns each byte into one lookup, which matters over a megabyte of pixels.
local crcTable: { number } = {}
do
	for index = 0, 255 do
		local value = index
		for _ = 1, 8 do
			if value % 2 == 1 then
				value = bit32.bxor(0xEDB88320, bit32.rshift(value, 1))
			else
				value = bit32.rshift(value, 1)
			end
		end
		crcTable[index] = value
	end
end

local function crc32(data: buffer, from: number, count: number): number
	local crc = 0xFFFFFFFF
	for offset = from, from + count - 1 do
		local index = bit32.band(bit32.bxor(crc, buffer.readu8(data, offset)), 0xFF)
		crc = bit32.bxor(crcTable[index], bit32.rshift(crc, 8))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

--[[
	Adler-32, which zlib carries and PNG readers check.

	The modulo runs every 4096 bytes rather than every byte: both accumulators
	stay well inside 2^53 over that span, so the arithmetic is exact and the cost
	is paid a few thousand times instead of a few million.
]]
local function adler32(data: buffer, length: number): number
	local a, b = 1, 0
	local index = 0
	while index < length do
		local chunkEnd = math.min(index + 4096, length)
		while index < chunkEnd do
			a += buffer.readu8(data, index)
			b += a
			index += 1
		end
		a %= 65521
		b %= 65521
	end
	return bit32.bor(bit32.lshift(b, 16), a)
end

local function writeU32(out: buffer, offset: number, value: number)
	buffer.writeu8(out, offset, bit32.band(bit32.rshift(value, 24), 0xFF))
	buffer.writeu8(out, offset + 1, bit32.band(bit32.rshift(value, 16), 0xFF))
	buffer.writeu8(out, offset + 2, bit32.band(bit32.rshift(value, 8), 0xFF))
	buffer.writeu8(out, offset + 3, bit32.band(value, 0xFF))
end

--[[
	One PNG chunk: length, type, payload, CRC over type and payload.
]]
local function writeChunk(out: buffer, offset: number, kind: string, payload: buffer, payloadLength: number): number
	writeU32(out, offset, payloadLength)
	buffer.writestring(out, offset + 4, kind)
	if payloadLength > 0 then
		buffer.copy(out, offset + 8, payload, 0, payloadLength)
	end
	writeU32(out, offset + 8 + payloadLength, crc32(out, offset + 4, payloadLength + 4))
	return offset + 12 + payloadLength
end

--[[
	Encodes 8-bit RGB pixels as a PNG.

	`rgb` holds width * height * 3 bytes, row-major, no padding. Alpha is dropped
	before this point: a screenshot has none worth keeping and carrying it would
	add a quarter to every byte that follows.
]]
function Png.encode(rgb: buffer, width: number, height: number): buffer
	-- PNG wants a filter byte at the start of every scanline. Filter 0 means
	-- "stored as-is", which is what makes the rest of this a straight copy.
	local rowBytes = width * 3
	local rawLength = (rowBytes + 1) * height
	local raw = buffer.create(rawLength)
	for row = 0, height - 1 do
		local target = row * (rowBytes + 1)
		buffer.writeu8(raw, target, 0)
		buffer.copy(raw, target + 1, rgb, row * rowBytes, rowBytes)
	end

	-- zlib: 0x78 0x01 header, stored deflate blocks, Adler-32 trailer.
	local MAX_BLOCK = 65535
	local blocks = math.max(1, math.ceil(rawLength / MAX_BLOCK))
	local zlibLength = 2 + blocks * 5 + rawLength + 4
	local zlib = buffer.create(zlibLength)
	buffer.writeu8(zlib, 0, 0x78)
	buffer.writeu8(zlib, 1, 0x01)

	local readOffset = 0
	local writeOffset = 2
	for index = 1, blocks do
		local size = math.min(MAX_BLOCK, rawLength - readOffset)
		buffer.writeu8(zlib, writeOffset, if index == blocks then 1 else 0)
		-- LEN then its one's complement, both little-endian.
		buffer.writeu8(zlib, writeOffset + 1, bit32.band(size, 0xFF))
		buffer.writeu8(zlib, writeOffset + 2, bit32.band(bit32.rshift(size, 8), 0xFF))
		buffer.writeu8(zlib, writeOffset + 3, bit32.band(bit32.bnot(size), 0xFF))
		buffer.writeu8(zlib, writeOffset + 4, bit32.band(bit32.rshift(bit32.bnot(size), 8), 0xFF))
		buffer.copy(zlib, writeOffset + 5, raw, readOffset, size)
		readOffset += size
		writeOffset += 5 + size
	end
	writeU32(zlib, writeOffset, adler32(raw, rawLength))

	local header = buffer.create(13)
	writeU32(header, 0, width)
	writeU32(header, 4, height)
	buffer.writeu8(header, 8, 8) -- bit depth
	buffer.writeu8(header, 9, 2) -- colour type 2: truecolour RGB
	buffer.writeu8(header, 10, 0) -- deflate
	buffer.writeu8(header, 11, 0) -- adaptive filtering
	buffer.writeu8(header, 12, 0) -- no interlace

	local total = 8 + (12 + 13) + (12 + zlibLength) + 12
	local out = buffer.create(total)
	-- Signature: the high bit and the CRLF pair catch transports that would
	-- mangle the file without anyone noticing.
	buffer.writeu8(out, 0, 0x89)
	buffer.writestring(out, 1, "PNG\r\n")
	buffer.writeu8(out, 6, 0x1A)
	buffer.writeu8(out, 7, 0x0A)

	local offset = writeChunk(out, 8, "IHDR", header, 13)
	offset = writeChunk(out, offset, "IDAT", zlib, zlibLength)
	writeChunk(out, offset, "IEND", buffer.create(0), 0)
	return out
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--[[
	Base64, three bytes at a time.

	Assembled into a table of chunks and concatenated once at the end. Appending
	to a string in a loop would rebuild the whole thing on every pass, which over
	a megabyte is the difference between prompt and unusable.
]]
function Png.base64(data: buffer): string
	local length = buffer.len(data)
	local pieces: { string } = {}
	local index = 0

	while index + 3 <= length do
		local a, b, c = buffer.readu8(data, index), buffer.readu8(data, index + 1), buffer.readu8(data, index + 2)
		local packed = bit32.bor(bit32.lshift(a, 16), bit32.lshift(b, 8), c)
		table.insert(
			pieces,
			string.sub(BASE64, bit32.rshift(packed, 18) + 1, bit32.rshift(packed, 18) + 1)
				.. string.sub(BASE64, bit32.band(bit32.rshift(packed, 12), 63) + 1, bit32.band(bit32.rshift(packed, 12), 63) + 1)
				.. string.sub(BASE64, bit32.band(bit32.rshift(packed, 6), 63) + 1, bit32.band(bit32.rshift(packed, 6), 63) + 1)
				.. string.sub(BASE64, bit32.band(packed, 63) + 1, bit32.band(packed, 63) + 1)
		)
		index += 3
	end

	local remaining = length - index
	if remaining == 1 then
		local a = buffer.readu8(data, index)
		local packed = bit32.lshift(a, 16)
		table.insert(
			pieces,
			string.sub(BASE64, bit32.rshift(packed, 18) + 1, bit32.rshift(packed, 18) + 1)
				.. string.sub(BASE64, bit32.band(bit32.rshift(packed, 12), 63) + 1, bit32.band(bit32.rshift(packed, 12), 63) + 1)
				.. "=="
		)
	elseif remaining == 2 then
		local a, b = buffer.readu8(data, index), buffer.readu8(data, index + 1)
		local packed = bit32.bor(bit32.lshift(a, 16), bit32.lshift(b, 8))
		table.insert(
			pieces,
			string.sub(BASE64, bit32.rshift(packed, 18) + 1, bit32.rshift(packed, 18) + 1)
				.. string.sub(BASE64, bit32.band(bit32.rshift(packed, 12), 63) + 1, bit32.band(bit32.rshift(packed, 12), 63) + 1)
				.. string.sub(BASE64, bit32.band(bit32.rshift(packed, 6), 63) + 1, bit32.band(bit32.rshift(packed, 6), 63) + 1)
				.. "="
		)
	end

	return table.concat(pieces)
end

--[[
	Nearest-neighbour downscale, RGBA in and RGB out.

	Nearest rather than averaged on purpose. A screenshot is read for what is in
	it -- is the part there, is the GUI covering it, is the material wrong -- and
	averaging softens exactly the thin edges and one-pixel text that carry that.
	It is also a single read per output pixel instead of four.
]]
function Png.downscaleToRgb(rgba: buffer, width: number, height: number, targetWidth: number): (buffer, number, number)
	local scale = math.min(1, targetWidth / width)
	local outWidth = math.max(1, math.floor(width * scale))
	local outHeight = math.max(1, math.floor(height * scale))
	local out = buffer.create(outWidth * outHeight * 3)

	for row = 0, outHeight - 1 do
		local sourceRow = math.min(height - 1, math.floor(row / scale))
		local sourceRowBase = sourceRow * width * 4
		local targetRowBase = row * outWidth * 3
		for column = 0, outWidth - 1 do
			local sourceColumn = math.min(width - 1, math.floor(column / scale))
			local source = sourceRowBase + sourceColumn * 4
			local target = targetRowBase + column * 3
			buffer.writeu8(out, target, buffer.readu8(rgba, source))
			buffer.writeu8(out, target + 1, buffer.readu8(rgba, source + 1))
			buffer.writeu8(out, target + 2, buffer.readu8(rgba, source + 2))
		end
	end

	return out, outWidth, outHeight
end

return Png
