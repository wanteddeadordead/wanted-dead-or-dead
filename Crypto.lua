-- Wanted: signatures. SHA-512 and Ed25519 (RFC 8032) in plain Lua 5.1: numbers are doubles, bitwise work goes
-- through the game's `bit` library (inputs taken modulo 2^32, unsigned 32-bit results). Signing.lua makes the keys
-- and signs; Verify.lua checks other players' records.
-- A check can run a little at a time (Crypto:NewCheck, Crypto:RunCheck): it pauses at checkpoints inside the hash,
-- the key decoding and the curve arithmetic, none of which runs much over a millisecond in the game.
-- Measured in the game (2026-10-09): a key 17.5 ms, a signature 20.4 ms, a check 23.0 ms, preparing a key 2.2 ms.

local _, Wanted = ...
local Crypto = Wanted:NewModule("Crypto")
local private = {
	-- Called at each checkpoint while a check runs a little at a time; nil otherwise
	step = nil,
	-- The self-test: nil until it has run, then true (passed) or false (failed: nothing is signed or checked)
	selfTest = nil,
	selfTestText = "not run yet",
}
local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift
local byte, char, floor = string.byte, string.char, math.floor

local function Checkpoint()
	local step = private.step
	if step then
		step()
	end
end



-- ============================================================================
-- SHA-512
-- ============================================================================

-- 64-bit words are hi/lo pairs of doubles; additions are done in doubles and reduced with %, so no 64-bit integer
-- operation is used. The constants are {hi, lo} halves.
local K = {1116352408,3609767458,1899447441,602891725,3049323471,3964484399,3921009573,2173295548,961987163,4081628472,1508970993,3053834265,2453635748,2937671579,2870763221,3664609560,3624381080,2734883394,310598401,1164996542,607225278,1323610764,1426881987,3590304994,1925078388,4068182383,2162078206,991336113,2614888103,633803317,3248222580,3479774868,3835390401,2666613458,4022224774,944711139,264347078,2341262773,604807628,2007800933,770255983,1495990901,1249150122,1856431235,1555081692,3175218132,1996064986,2198950837,2554220882,3999719339,2821834349,766784016,2952996808,2566594879,3210313671,3203337956,3336571891,1034457026,3584528711,2466948901,113926993,3758326383,338241895,168717936,666307205,1188179964,773529912,1546045734,1294757372,1522805485,1396182291,2643833823,1695183700,2343527390,1986661051,1014477480,2177026350,1206759142,2456956037,344077627,2730485921,1290863460,2820302411,3158454273,3259730800,3505952657,3345764771,106217008,3516065817,3606008344,3600352804,1432725776,4094571909,1467031594,275423344,851169720,430227734,3100823752,506948616,1363258195,659060556,3750685593,883997877,3785050280,958139571,3318307427,1322822218,3812723403,1537002063,2003034995,1747873779,3602036899,1955562222,1575990012,2024104815,1125592928,2227730452,2716904306,2361852424,442776044,2428436474,593698344,2756734187,3733110249,3204031479,2999351573,3329325298,3815920427,3391569614,3928383900,3515267271,566280711,3940187606,3454069534,4118630271,4000239992,116418474,1914138554,174292421,2731055270,289380356,3203993006,460393269,320620315,685471733,587496836,852142971,1086792851,1017036298,365543100,1126000580,2618297676,1288033470,3409855158,1501505948,4234509866,1607167915,987167468,1816402316,1246189591}
local H0 = {1779033703,4089235720,3144134277,2227873595,1013904242,4271175723,2773480762,1595750129,1359893119,2917565137,2600822924,725511199,528734635,4215389547,1541459225,327033209}
local W32 = 4294967296

local Wh, Wl = {}, {}

-- rotr of (hi, lo) by n bits, n < 32
local function rotr(hi, lo, n)
	return bor(rshift(hi, n), lshift(lo, 32 - n)), bor(rshift(lo, n), lshift(hi, 32 - n))
end

local function block(Hh, Hl, s, off)
	for i = 0, 15 do
		local p = off + i * 8
		local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, p, p + 7)
		Wh[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
		Wl[i] = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
	end
	for i = 16, 79 do
		-- s0 = rotr1 ^ rotr8 ^ shr7 of W[i-15]
		local h, l = Wh[i - 15], Wl[i - 15]
		local r1h, r1l = rotr(h, l, 1)
		local r8h, r8l = rotr(h, l, 8)
		local s0h = bxor(bxor(r1h, r8h), rshift(h, 7))
		local s0l = bxor(bxor(r1l, r8l), bor(rshift(l, 7), lshift(h, 25)))
		-- s1 = rotr19 ^ rotr61 ^ shr6 of W[i-2]
		h, l = Wh[i - 2], Wl[i - 2]
		local r19h, r19l = rotr(h, l, 19)
		local r61h, r61l = rotr(l, h, 29) -- rotr 61 = swap, then rotr 29
		local s1h = bxor(bxor(r19h, r61h), rshift(h, 6))
		local s1l = bxor(bxor(r19l, r61l), bor(rshift(l, 6), lshift(h, 26)))
		local lo = s0l + s1l + Wl[i - 16] + Wl[i - 7]
		local nl = lo % W32
		Wh[i] = (s0h + s1h + Wh[i - 16] + Wh[i - 7] + (lo - nl) / W32) % W32
		Wl[i] = nl
	end
	-- A block is about 0.8 ms in the game: checkpoints after the schedule and halfway through the rounds
	Checkpoint()
	local ah, al, bh, bl, ch, cl, dh, dl = Hh[1], Hl[1], Hh[2], Hl[2], Hh[3], Hl[3], Hh[4], Hl[4]
	local eh, el, fh, fl, gh, gl, hh, hl = Hh[5], Hl[5], Hh[6], Hl[6], Hh[7], Hl[7], Hh[8], Hl[8]
	for i = 0, 79 do
		-- S1 = rotr14 ^ rotr18 ^ rotr41 of e
		local r14h, r14l = rotr(eh, el, 14)
		local r18h, r18l = rotr(eh, el, 18)
		local r41h, r41l = rotr(el, eh, 9)
		local S1h, S1l = bxor(bxor(r14h, r18h), r41h), bxor(bxor(r14l, r18l), r41l)
		local chh = bxor(band(eh, fh), band(bnot(eh), gh))
		local chl = bxor(band(el, fl), band(bnot(el), gl))
		local t1l = hl + S1l + chl + K[i * 2 + 2] + Wl[i]
		local t1h = hh + S1h + chh + K[i * 2 + 1] + Wh[i]
		-- S0 = rotr28 ^ rotr34 ^ rotr39 of a
		local r28h, r28l = rotr(ah, al, 28)
		local r34h, r34l = rotr(al, ah, 2)
		local r39h, r39l = rotr(al, ah, 7)
		local S0h, S0l = bxor(bxor(r28h, r34h), r39h), bxor(bxor(r28l, r34l), r39l)
		local mjh = bxor(bxor(band(ah, bh), band(ah, ch)), band(bh, ch))
		local mjl = bxor(bxor(band(al, bl), band(al, cl)), band(bl, cl))
		hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
		local x = dl + t1l
		el = x % W32
		eh = (dh + t1h + (x - el) / W32) % W32
		dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
		x = t1l + S0l + mjl
		al = x % W32
		ah = (t1h + S0h + mjh + (x - al) / W32) % W32
		if i == 39 then
			Checkpoint()
		end
	end
	local v = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
	for i = 1, 8 do
		local x = Hl[i] + v[i * 2]
		local nl = x % W32
		Hh[i] = (Hh[i] + v[i * 2 - 1] + (x - nl) / W32) % W32
		Hl[i] = nl
	end
end

local function be32(x)
	return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
end

---SHA-512 of a string: the 64-byte digest.
---@param msg string
---@return string
local function sha512(msg)
	local Hh, Hl = {}, {}
	for i = 1, 8 do Hh[i], Hl[i] = H0[i * 2 - 1], H0[i * 2] end
	local n = #msg
	local pad = 128 - (n + 17) % 128
	if pad == 128 then pad = 0 end
	local bits = n * 8
	msg = msg .. "\128" .. string.rep("\0", pad + 8) .. be32(floor(bits / W32)) .. be32(bits % W32)
	for off = 1, #msg, 128 do
		block(Hh, Hl, msg, off)
		Checkpoint()
	end
	local out = {}
	for i = 1, 8 do out[#out + 1] = be32(Hh[i]) out[#out + 1] = be32(Hl[i]) end
	return table.concat(out)
end



-- ============================================================================
-- The field (integers mod 2^255 - 19), as 16 limbs of 16 bits (generated by gen_field.py)
-- ============================================================================

-- Carries go by adding and taking away 1.5 * 2^68, which rounds a double to a whole multiple of 2^16 without
-- math.floor
local CK, INV = 1.5 * 2 ^ 68, 1 / 65536
local F = {}
function F.mul(o, a, b)
	local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
	local b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16]
	local t0 = a0*b0
	local t1 = a0*b1 + a1*b0
	local t2 = a0*b2 + a1*b1 + a2*b0
	local t3 = a0*b3 + a1*b2 + a2*b1 + a3*b0
	local t4 = a0*b4 + a1*b3 + a2*b2 + a3*b1 + a4*b0
	local t5 = a0*b5 + a1*b4 + a2*b3 + a3*b2 + a4*b1 + a5*b0
	local t6 = a0*b6 + a1*b5 + a2*b4 + a3*b3 + a4*b2 + a5*b1 + a6*b0
	local t7 = a0*b7 + a1*b6 + a2*b5 + a3*b4 + a4*b3 + a5*b2 + a6*b1 + a7*b0
	local t8 = a0*b8 + a1*b7 + a2*b6 + a3*b5 + a4*b4 + a5*b3 + a6*b2 + a7*b1 + a8*b0
	local t9 = a0*b9 + a1*b8 + a2*b7 + a3*b6 + a4*b5 + a5*b4 + a6*b3 + a7*b2 + a8*b1 + a9*b0
	local t10 = a0*b10 + a1*b9 + a2*b8 + a3*b7 + a4*b6 + a5*b5 + a6*b4 + a7*b3 + a8*b2 + a9*b1 + a10*b0
	local t11 = a0*b11 + a1*b10 + a2*b9 + a3*b8 + a4*b7 + a5*b6 + a6*b5 + a7*b4 + a8*b3 + a9*b2 + a10*b1 + a11*b0
	local t12 = a0*b12 + a1*b11 + a2*b10 + a3*b9 + a4*b8 + a5*b7 + a6*b6 + a7*b5 + a8*b4 + a9*b3 + a10*b2 + a11*b1 + a12*b0
	local t13 = a0*b13 + a1*b12 + a2*b11 + a3*b10 + a4*b9 + a5*b8 + a6*b7 + a7*b6 + a8*b5 + a9*b4 + a10*b3 + a11*b2 + a12*b1 + a13*b0
	local t14 = a0*b14 + a1*b13 + a2*b12 + a3*b11 + a4*b10 + a5*b9 + a6*b8 + a7*b7 + a8*b6 + a9*b5 + a10*b4 + a11*b3 + a12*b2 + a13*b1 + a14*b0
	local t15 = a0*b15 + a1*b14 + a2*b13 + a3*b12 + a4*b11 + a5*b10 + a6*b9 + a7*b8 + a8*b7 + a9*b6 + a10*b5 + a11*b4 + a12*b3 + a13*b2 + a14*b1 + a15*b0
	local t16 = a1*b15 + a2*b14 + a3*b13 + a4*b12 + a5*b11 + a6*b10 + a7*b9 + a8*b8 + a9*b7 + a10*b6 + a11*b5 + a12*b4 + a13*b3 + a14*b2 + a15*b1
	local t17 = a2*b15 + a3*b14 + a4*b13 + a5*b12 + a6*b11 + a7*b10 + a8*b9 + a9*b8 + a10*b7 + a11*b6 + a12*b5 + a13*b4 + a14*b3 + a15*b2
	local t18 = a3*b15 + a4*b14 + a5*b13 + a6*b12 + a7*b11 + a8*b10 + a9*b9 + a10*b8 + a11*b7 + a12*b6 + a13*b5 + a14*b4 + a15*b3
	local t19 = a4*b15 + a5*b14 + a6*b13 + a7*b12 + a8*b11 + a9*b10 + a10*b9 + a11*b8 + a12*b7 + a13*b6 + a14*b5 + a15*b4
	local t20 = a5*b15 + a6*b14 + a7*b13 + a8*b12 + a9*b11 + a10*b10 + a11*b9 + a12*b8 + a13*b7 + a14*b6 + a15*b5
	local t21 = a6*b15 + a7*b14 + a8*b13 + a9*b12 + a10*b11 + a11*b10 + a12*b9 + a13*b8 + a14*b7 + a15*b6
	local t22 = a7*b15 + a8*b14 + a9*b13 + a10*b12 + a11*b11 + a12*b10 + a13*b9 + a14*b8 + a15*b7
	local t23 = a8*b15 + a9*b14 + a10*b13 + a11*b12 + a12*b11 + a13*b10 + a14*b9 + a15*b8
	local t24 = a9*b15 + a10*b14 + a11*b13 + a12*b12 + a13*b11 + a14*b10 + a15*b9
	local t25 = a10*b15 + a11*b14 + a12*b13 + a13*b12 + a14*b11 + a15*b10
	local t26 = a11*b15 + a12*b14 + a13*b13 + a14*b12 + a15*b11
	local t27 = a12*b15 + a13*b14 + a14*b13 + a15*b12
	local t28 = a13*b15 + a14*b14 + a15*b13
	local t29 = a14*b15 + a15*b14
	local t30 = a15*b15
	t0 = t0 + 38 * t16
	t1 = t1 + 38 * t17
	t2 = t2 + 38 * t18
	t3 = t3 + 38 * t19
	t4 = t4 + 38 * t20
	t5 = t5 + 38 * t21
	t6 = t6 + 38 * t22
	t7 = t7 + 38 * t23
	t8 = t8 + 38 * t24
	t9 = t9 + 38 * t25
	t10 = t10 + 38 * t26
	t11 = t11 + 38 * t27
	t12 = t12 + 38 * t28
	t13 = t13 + 38 * t29
	t14 = t14 + 38 * t30
	local c
	c = (t0 + CK) - CK t0 = t0 - c
	t1 = t1 + c * INV
	c = (t1 + CK) - CK t1 = t1 - c
	t2 = t2 + c * INV
	c = (t2 + CK) - CK t2 = t2 - c
	t3 = t3 + c * INV
	c = (t3 + CK) - CK t3 = t3 - c
	t4 = t4 + c * INV
	c = (t4 + CK) - CK t4 = t4 - c
	t5 = t5 + c * INV
	c = (t5 + CK) - CK t5 = t5 - c
	t6 = t6 + c * INV
	c = (t6 + CK) - CK t6 = t6 - c
	t7 = t7 + c * INV
	c = (t7 + CK) - CK t7 = t7 - c
	t8 = t8 + c * INV
	c = (t8 + CK) - CK t8 = t8 - c
	t9 = t9 + c * INV
	c = (t9 + CK) - CK t9 = t9 - c
	t10 = t10 + c * INV
	c = (t10 + CK) - CK t10 = t10 - c
	t11 = t11 + c * INV
	c = (t11 + CK) - CK t11 = t11 - c
	t12 = t12 + c * INV
	c = (t12 + CK) - CK t12 = t12 - c
	t13 = t13 + c * INV
	c = (t13 + CK) - CK t13 = t13 - c
	t14 = t14 + c * INV
	c = (t14 + CK) - CK t14 = t14 - c
	t15 = t15 + c * INV
	c = (t15 + CK) - CK t15 = t15 - c
	t0 = t0 + 38 * c * INV
	c = (t0 + CK) - CK t0 = t0 - c t1 = t1 + c * INV
	o[1] = t0 o[2] = t1 o[3] = t2 o[4] = t3 o[5] = t4 o[6] = t5 o[7] = t6 o[8] = t7 o[9] = t8 o[10] = t9 o[11] = t10 o[12] = t11 o[13] = t12 o[14] = t13 o[15] = t14 o[16] = t15
end
function F.sq(o, a)
	local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
	local d0, d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11, d12, d13, d14, d15 = 2*a0, 2*a1, 2*a2, 2*a3, 2*a4, 2*a5, 2*a6, 2*a7, 2*a8, 2*a9, 2*a10, 2*a11, 2*a12, 2*a13, 2*a14, 2*a15
	local t0 = a0*a0
	local t1 = d0*a1
	local t2 = d0*a2 + a1*a1
	local t3 = d0*a3 + d1*a2
	local t4 = d0*a4 + d1*a3 + a2*a2
	local t5 = d0*a5 + d1*a4 + d2*a3
	local t6 = d0*a6 + d1*a5 + d2*a4 + a3*a3
	local t7 = d0*a7 + d1*a6 + d2*a5 + d3*a4
	local t8 = d0*a8 + d1*a7 + d2*a6 + d3*a5 + a4*a4
	local t9 = d0*a9 + d1*a8 + d2*a7 + d3*a6 + d4*a5
	local t10 = d0*a10 + d1*a9 + d2*a8 + d3*a7 + d4*a6 + a5*a5
	local t11 = d0*a11 + d1*a10 + d2*a9 + d3*a8 + d4*a7 + d5*a6
	local t12 = d0*a12 + d1*a11 + d2*a10 + d3*a9 + d4*a8 + d5*a7 + a6*a6
	local t13 = d0*a13 + d1*a12 + d2*a11 + d3*a10 + d4*a9 + d5*a8 + d6*a7
	local t14 = d0*a14 + d1*a13 + d2*a12 + d3*a11 + d4*a10 + d5*a9 + d6*a8 + a7*a7
	local t15 = d0*a15 + d1*a14 + d2*a13 + d3*a12 + d4*a11 + d5*a10 + d6*a9 + d7*a8
	local t16 = d1*a15 + d2*a14 + d3*a13 + d4*a12 + d5*a11 + d6*a10 + d7*a9 + a8*a8
	local t17 = d2*a15 + d3*a14 + d4*a13 + d5*a12 + d6*a11 + d7*a10 + d8*a9
	local t18 = d3*a15 + d4*a14 + d5*a13 + d6*a12 + d7*a11 + d8*a10 + a9*a9
	local t19 = d4*a15 + d5*a14 + d6*a13 + d7*a12 + d8*a11 + d9*a10
	local t20 = d5*a15 + d6*a14 + d7*a13 + d8*a12 + d9*a11 + a10*a10
	local t21 = d6*a15 + d7*a14 + d8*a13 + d9*a12 + d10*a11
	local t22 = d7*a15 + d8*a14 + d9*a13 + d10*a12 + a11*a11
	local t23 = d8*a15 + d9*a14 + d10*a13 + d11*a12
	local t24 = d9*a15 + d10*a14 + d11*a13 + a12*a12
	local t25 = d10*a15 + d11*a14 + d12*a13
	local t26 = d11*a15 + d12*a14 + a13*a13
	local t27 = d12*a15 + d13*a14
	local t28 = d13*a15 + a14*a14
	local t29 = d14*a15
	local t30 = a15*a15
	t0 = t0 + 38 * t16
	t1 = t1 + 38 * t17
	t2 = t2 + 38 * t18
	t3 = t3 + 38 * t19
	t4 = t4 + 38 * t20
	t5 = t5 + 38 * t21
	t6 = t6 + 38 * t22
	t7 = t7 + 38 * t23
	t8 = t8 + 38 * t24
	t9 = t9 + 38 * t25
	t10 = t10 + 38 * t26
	t11 = t11 + 38 * t27
	t12 = t12 + 38 * t28
	t13 = t13 + 38 * t29
	t14 = t14 + 38 * t30
	local c
	c = (t0 + CK) - CK t0 = t0 - c
	t1 = t1 + c * INV
	c = (t1 + CK) - CK t1 = t1 - c
	t2 = t2 + c * INV
	c = (t2 + CK) - CK t2 = t2 - c
	t3 = t3 + c * INV
	c = (t3 + CK) - CK t3 = t3 - c
	t4 = t4 + c * INV
	c = (t4 + CK) - CK t4 = t4 - c
	t5 = t5 + c * INV
	c = (t5 + CK) - CK t5 = t5 - c
	t6 = t6 + c * INV
	c = (t6 + CK) - CK t6 = t6 - c
	t7 = t7 + c * INV
	c = (t7 + CK) - CK t7 = t7 - c
	t8 = t8 + c * INV
	c = (t8 + CK) - CK t8 = t8 - c
	t9 = t9 + c * INV
	c = (t9 + CK) - CK t9 = t9 - c
	t10 = t10 + c * INV
	c = (t10 + CK) - CK t10 = t10 - c
	t11 = t11 + c * INV
	c = (t11 + CK) - CK t11 = t11 - c
	t12 = t12 + c * INV
	c = (t12 + CK) - CK t12 = t12 - c
	t13 = t13 + c * INV
	c = (t13 + CK) - CK t13 = t13 - c
	t14 = t14 + c * INV
	c = (t14 + CK) - CK t14 = t14 - c
	t15 = t15 + c * INV
	c = (t15 + CK) - CK t15 = t15 - c
	t0 = t0 + 38 * c * INV
	c = (t0 + CK) - CK t0 = t0 - c t1 = t1 + c * INV
	o[1] = t0 o[2] = t1 o[3] = t2 o[4] = t3 o[5] = t4 o[6] = t5 o[7] = t6 o[8] = t7 o[9] = t8 o[10] = t9 o[11] = t10 o[12] = t11 o[13] = t12 o[14] = t13 o[15] = t14 o[16] = t15
end

local mul, sq = F.mul, F.sq



-- ============================================================================
-- Ed25519
-- ============================================================================

-- The TweetNaCl field with an unrolled multiply and square, extended coordinates with a 4S+4M doubling, 4-bit fixed
-- windows (a check does [s]B + [h](-A) in one pass) and ref10's addition chains for inversion and square root.

local function gf(init)
	local r = {}
	for i = 1, 16 do r[i] = init and init[i] or 0 end
	return r
end
local function set(r, a) for i = 1, 16 do r[i] = a[i] end end
local function add(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function sub(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end

local gf0, gf1 = gf(), gf({ 1 })
local D = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local BX = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local BY = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local SQRTM1 = gf({ 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 })

-- The canonical bytes of a field element (TweetNaCl's pack25519, with floor carries for signed limbs)
local function car(o)
	for i = 1, 16 do
		local c = floor(o[i] / 65536)
		o[i] = o[i] - c * 65536
		if i < 16 then o[i + 1] = o[i + 1] + c else o[1] = o[1] + 38 * c end
	end
end
local pt, pm = gf(), gf()
local function pack(o, n)
	set(pt, n)
	car(pt) car(pt) car(pt)
	for _ = 1, 2 do
		pm[1] = pt[1] - 0xffed
		for i = 2, 15 do
			local b = pm[i - 1] < 0 and 1 or 0
			pm[i - 1] = pm[i - 1] + b * 65536
			pm[i] = pt[i] - 0xffff - b
		end
		local b = pm[15] < 0 and 1 or 0
		pm[15] = pm[15] + b * 65536
		pm[16] = pt[16] - 0x7fff - b
		if pm[16] >= 0 then set(pt, pm) end
	end
	for i = 1, 16 do
		o[2 * i - 1] = pt[i] % 256
		o[2 * i] = floor(pt[i] / 256)
	end
	return o
end
local function eq(a, b)
	local x, y = pack({}, a), pack({}, b)
	for i = 1, 32 do if x[i] ~= y[i] then return false end end
	return true
end
local function parity(a) return pack({}, a)[1] % 2 end

-- n squarings; a checkpoint after each 25, about a quarter of a millisecond in the game
local function sqn(o, a, n)
	sq(o, a)
	for i = 2, n do
		sq(o, o)
		if i % 25 == 0 then Checkpoint() end
	end
end
-- z^(p-2) (ref10 fe_invert)
local i0, i1, i2, i3 = gf(), gf(), gf(), gf()
local function inv(o, z)
	sq(i0, z) sqn(i1, i0, 2) mul(i1, z, i1) mul(i0, i0, i1) sq(i2, i0) mul(i1, i1, i2)
	sqn(i2, i1, 5) mul(i1, i2, i1) sqn(i2, i1, 10) mul(i2, i2, i1) sqn(i3, i2, 20) mul(i2, i3, i2)
	sqn(i2, i2, 10) mul(i1, i2, i1) sqn(i2, i1, 50) mul(i2, i2, i1) sqn(i3, i2, 100) mul(i2, i3, i2)
	sqn(i2, i2, 50) mul(i1, i2, i1) sqn(i1, i1, 5) mul(o, i1, i0)
end
-- z^((p-5)/8) (ref10 fe_pow22523)
local function pow22523(o, z)
	sq(i0, z) sqn(i1, i0, 2) mul(i1, z, i1) mul(i0, i0, i1) sq(i0, i0) mul(i0, i1, i0)
	sqn(i1, i0, 5) mul(i0, i1, i0) sqn(i1, i0, 10) mul(i1, i1, i0) sqn(i2, i1, 20) mul(i1, i2, i1)
	sqn(i1, i1, 10) mul(i0, i1, i0) sqn(i1, i0, 50) mul(i1, i1, i0) sqn(i2, i1, 100) mul(i1, i2, i1)
	sqn(i1, i1, 50) mul(i0, i1, i0) sqn(i0, i0, 2) mul(o, i0, z)
end

-- Points: extended {X, Y, Z, T}; cached {Y+X, Y-X, Z, 2dT}
local function point() return { gf(), gf(), gf(), gf() } end
local ga, gb, gc, gd, ge, gfv, gg, gh = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()

local function dbl(p) -- p = 2p
	local X, Y, Z, T = p[1], p[2], p[3], p[4]
	sq(ga, X) sq(gb, Y) sq(gc, Z) add(gc, gc, gc)
	add(gh, ga, gb) add(ge, X, Y) sq(ge, ge) sub(ge, gh, ge)
	sub(gg, ga, gb) add(gfv, gc, gg)
	mul(X, ge, gfv) mul(Y, gg, gh) mul(T, ge, gh) mul(Z, gfv, gg)
end

local function addc(p, q) -- p = p + q, q cached
	local X, Y, Z, T = p[1], p[2], p[3], p[4]
	sub(ga, Y, X) mul(ga, ga, q[2])
	add(gb, Y, X) mul(gb, gb, q[1])
	mul(gc, T, q[4])
	mul(gd, Z, q[3]) add(gd, gd, gd)
	sub(ge, gb, ga) sub(gfv, gd, gc) add(gg, gd, gc) add(gh, gb, ga)
	mul(X, ge, gfv) mul(Y, gg, gh) mul(Z, gfv, gg) mul(T, ge, gh)
end

local function tocached(c, p)
	add(c[1], p[2], p[1]) sub(c[2], p[2], p[1]) set(c[3], p[3]) mul(c[4], p[4], D2)
	return c
end

local function identity(p) set(p[1], gf0) set(p[2], gf1) set(p[3], gf1) set(p[4], gf0) end

-- table[j] = j * P (cached), j = 1..15
local function window(P)
	local tab, acc = {}, point()
	for i = 1, 4 do set(acc[i], P[i]) end
	tab[1] = tocached(point(), P)
	for j = 2, 15 do
		addc(acc, tab[1])
		tab[j] = tocached(point(), acc)
		if j % 5 == 0 then Checkpoint() end
	end
	return tab
end

local BASE = { gf(BX), gf(BY), gf(gf1), gf() }
mul(BASE[4], BX, BY)
local BTAB = window(BASE)

local function encode(p)
	local zi, x, y = gf(), gf(), gf()
	inv(zi, p[3]) mul(x, p[1], zi) mul(y, p[2], zi)
	local o = pack({}, y)
	o[32] = o[32] + 128 * parity(x)
	return o
end

-- Decodes a point and negates it (TweetNaCl's unpackneg); nil if it isn't on the curve
local function decodeneg(s)
	local r = point()
	local num, den, den2, den4, den6, t, chk = gf(), gf(), gf(), gf(), gf(), gf(), gf()
	set(r[3], gf1)
	local y = r[2]
	for i = 1, 16 do y[i] = s[2 * i - 1] + 256 * s[2 * i] end
	y[16] = y[16] % 32768
	sq(num, y) mul(den, num, D) sub(num, num, gf1) add(den, gf1, den)
	sq(den2, den) sq(den4, den2) mul(den6, den4, den2) mul(t, den6, num) mul(t, t, den)
	pow22523(t, t)
	mul(t, t, num) mul(t, t, den) mul(t, t, den) mul(r[1], t, den)
	sq(chk, r[1]) mul(chk, chk, den)
	if not eq(chk, num) then mul(r[1], r[1], SQRTM1) end
	sq(chk, r[1]) mul(chk, chk, den)
	if not eq(chk, num) then return nil end
	if parity(r[1]) == floor(s[32] / 128) then sub(r[1], gf0, r[1]) end
	mul(r[4], r[1], r[2])
	return r
end

-- Scalars: 32-byte little-endian arrays (1-indexed)
local L = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }
local function modL(r, x) -- TweetNaCl modL: x is 64 numbers, r gets 32 bytes
	local carry
	for i = 63, 32, -1 do
		carry = 0
		local xi, base = x[i + 1], i - 32
		for j = base, i - 13 do
			local v = x[j + 1] + carry - 16 * xi * L[j - base + 1]
			carry = floor((v + 128) / 256)
			x[j + 1] = v - carry * 256
		end
		x[i - 11] = x[i - 11] + carry
		x[i + 1] = 0
	end
	carry = 0
	for j = 1, 32 do
		local v = x[j] + carry - floor(x[32] / 16) * L[j]
		carry = floor(v / 256)
		x[j] = v % 256
	end
	for j = 1, 32 do x[j] = x[j] - carry * L[j] end
	for i = 1, 32 do
		x[i + 1] = x[i + 1] + floor(x[i] / 256)
		r[i] = x[i] % 256
	end
	return r
end
local function reduce64(s) return modL({}, { byte(s, 1, 64) }) end
local function belowL(s) -- s: 32-byte array; true if s < L
	for i = 32, 1, -1 do
		if s[i] < L[i] then return true elseif s[i] > L[i] then return false end
	end
	return false
end

local function nibbles(s)
	local n = {}
	for i = 1, 32 do
		local b = s[i]
		n[2 * i - 1] = b % 16
		n[2 * i] = (b - b % 16) / 16
	end
	return n
end

local function str(a) local o = {} for i = 1, #a do o[i] = char(a[i]) end return table.concat(o) end

-- [s]B
local function basemul(s)
	local n, p = nibbles(s), point()
	identity(p)
	for i = 64, 1, -1 do
		if i < 64 then dbl(p) dbl(p) dbl(p) dbl(p) end
		local k = n[i]
		if k > 0 then addc(p, BTAB[k]) end
	end
	return p
end

local function expand(seed)
	local h = { byte(sha512(seed), 1, 64) }
	h[1] = h[1] - h[1] % 8
	local b = h[32] % 128
	if b < 64 then b = b + 64 end
	h[32] = b
	return h
end

local function publickey(seed)
	local a = expand(seed)
	local s = {}
	for i = 1, 32 do s[i] = a[i] end
	return str(encode(basemul(s)))
end

local function sign(seed, pk, msg)
	local a = expand(seed)
	local prefix = {}
	for i = 33, 64 do prefix[#prefix + 1] = char(a[i]) end
	local r = reduce64(sha512(table.concat(prefix) .. msg))
	local R = str(encode(basemul(r)))
	local h = reduce64(sha512(R .. pk .. msg))
	local x = {}
	for i = 1, 64 do x[i] = 0 end
	for i = 1, 32 do x[i] = r[i] end
	for i = 1, 32 do
		local hi = h[i]
		for j = 1, 32 do x[i + j - 1] = x[i + j - 1] + hi * a[j] end
	end
	return R .. str(modL({}, x))
end

-- A public key made ready to check with: -A decoded and its window table. nil if pk isn't a point on the curve.
local function prepare(pk)
	if type(pk) ~= "string" or #pk ~= 32 then return nil end
	local negA = decodeneg({ byte(pk, 1, 32) })
	if not negA then return nil end
	Checkpoint()
	return { pk = pk, tab = window(negA) }
end

local function verify(key, msg, sig)
	if type(key) == "string" then key = prepare(key) end
	if not key or type(sig) ~= "string" or #sig ~= 64 then return false end
	local S = { byte(sig, 33, 64) }
	if not belowL(S) then return false end
	local h = reduce64(sha512(sig:sub(1, 32) .. key.pk .. msg))
	local ns, nh, tab = nibbles(S), nibbles(h), key.tab
	local p = point()
	identity(p)
	for i = 64, 1, -1 do
		if i < 64 then dbl(p) dbl(p) dbl(p) dbl(p) end
		local k = ns[i]
		if k > 0 then addc(p, BTAB[k]) end
		k = nh[i]
		if k > 0 then addc(p, tab[k]) end
		Checkpoint()
	end
	return str(encode(p)) == sig:sub(1, 32)
end



-- ============================================================================
-- Text forms: base64 (RFC 4648's standard alphabet, no padding) and hex
-- ============================================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, 64 do
	B64_VALUE[byte(B64, i)] = i - 1
end

---Bytes as base64 without padding: 32 bytes make 43 characters, 64 make 86.
---@param s string
---@return string
function Crypto:Base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local d1, d2, d3, d4 = floor(n / 262144), floor(n / 4096) % 64, floor(n / 64) % 64, n % 64
		out[#out + 1] = strsub(B64, d1 + 1, d1 + 1)..strsub(B64, d2 + 1, d2 + 1)
			..(b and strsub(B64, d3 + 1, d3 + 1) or "")..(c and strsub(B64, d4 + 1, d4 + 1) or "")
	end
	return table.concat(out)
end

---Base64 without padding back to bytes, or nil for anything else (another alphabet, padding, a length no bytes
---make, or bits left over that aren't zero: each value has one spelling).
---@param s any
---@return string?
function Crypto:FromBase64(s)
	if type(s) ~= "string" or #s % 4 == 1 then
		return nil
	end
	local out = {}
	for i = 1, #s, 4 do
		local n, count = 0, 0
		for j = i, min(i + 3, #s) do
			local v = B64_VALUE[byte(s, j)]
			if not v then
				return nil
			end
			n, count = n * 64 + v, count + 1
		end
		if count == 4 then
			out[#out + 1] = char(floor(n / 65536), floor(n / 256) % 256, n % 256)
		elseif count == 3 then
			if n % 4 ~= 0 then return nil end
			n = n / 4
			out[#out + 1] = char(floor(n / 256), n % 256)
		else
			if n % 16 ~= 0 then return nil end
			out[#out + 1] = char(n / 16)
		end
	end
	return table.concat(out)
end

---Hex (either case) to bytes, or nil if it isn't hex.
---@param s any
---@return string?
function Crypto:FromHex(s)
	if type(s) ~= "string" or #s % 2 ~= 0 or strfind(s, "[^%x]") then
		return nil
	end
	return (gsub(s, "..", function(x) return char(tonumber(x, 16)) end))
end

---Bytes as lower-case hex.
---@param s string
---@return string
function Crypto:Hex(s)
	return (gsub(s, ".", function(c) return format("%02x", byte(c)) end))
end



-- ============================================================================
-- Keys, signatures and checks
-- ============================================================================

---SHA-512 of a string: 64 bytes.
---@param s string
---@return string
function Crypto:SHA512(s)
	return sha512(s)
end

---The public key (32 bytes) of a 32-byte seed.
---@param seed string
---@return string
function Crypto:PublicKey(seed)
	return publickey(seed)
end

---A key's id: the first 6 bytes of its SHA-512 in base64, 8 characters. Only a hint for finding the key; a
---signature is always checked against the whole key.
---@param pk string 32 bytes
---@return string
function Crypto:KeyId(pk)
	return Crypto:Base64(strsub(sha512(pk), 1, 6))
end

---Signs a message: 64 bytes. All at once (about 20 ms in the game), so never in a fight.
---@param seed string 32 bytes
---@param pk string its public key
---@param msg string
---@return string
function Crypto:Sign(seed, pk, msg)
	return sign(seed, pk, msg)
end

---A public key decoded and ready to check with (about 2 ms in the game, 21 KB), or nil if it isn't a key.
---@param pk string 32 bytes
---@return table?
function Crypto:Prepare(pk)
	return prepare(pk)
end

---Checks a signature all at once. key is a public key or a prepared one.
---@param key string|table
---@param msg string
---@param sig string 64 bytes
---@return boolean
function Crypto:Verify(key, msg, sig)
	return verify(key, msg, sig)
end

---A check to run a little at a time with RunCheck. key is a public key (prepared first, inside the check: the job's
---key holds it after) or a prepared one.
---@param key string|table
---@param msg string
---@param sig string
---@return table job
function Crypto:NewCheck(key, msg, sig)
	local job = {}
	job.co = coroutine.create(function()
		if type(key) == "string" then
			key = prepare(key)
			job.key = key
		end
		return verify(key or false, msg, sig)
	end)
	return job
end

-- A slice pauses at the first checkpoint past YIELD_MS. No stretch between checkpoints takes much over a
-- millisecond in the game (a SHA-512 block, 25 squarings, a window of the check), so a slice stays under 3 ms.
Crypto.YIELD_MS = 2

---Runs a check for one slice: until it reaches ms (default YIELD_MS), then pauses. Returns true and the result once
---it's done (false for a check that failed with an error, which is logged), or false while there's more to do.
---@param job table from NewCheck
---@param ms number?
---@return boolean done
---@return boolean? ok
function Crypto:RunCheck(job, ms)
	if job.done then
		return true, job.ok
	end
	local limit = ms or Crypto.YIELD_MS
	local start = debugprofilestop()
	private.step = function()
		if debugprofilestop() - start >= limit then
			coroutine.yield()
		end
	end
	local resumed, result = coroutine.resume(job.co)
	private.step = nil
	if not resumed then
		Wanted:Log("!! Crypto: a check failed with an error: %s", tostring(result))
		job.done, job.ok = true, false
	elseif coroutine.status(job.co) == "dead" then
		job.done, job.ok = true, result == true
	end
	return job.done == true, job.ok
end

-- The longest stretch between checkpoints in the game, kept free at the end of a frame's work time
local STRETCH_MS = 1

---Runs a check in the background work, a slice a frame within what's left of the frame's work time, so never in
---a fight, and calls onDone(ok) when it's done.
---@param job table from NewCheck
---@param onDone fun(ok: boolean)
function Crypto:Check(job, onDone)
	local function Slice()
		local ms = min(Crypto.YIELD_MS, Wanted:WorkTimeLeft() - STRETCH_MS)
		local done, ok = false, nil
		if ms > 0 then
			done, ok = Crypto:RunCheck(job, ms)
		end
		if done then
			onDone(ok)
		else
			-- The next frame: work queued now would run again in this one
			C_Timer.After(0, function() Wanted:QueueWork(Slice) end)
		end
	end
	Wanted:QueueWork(Slice)
end



-- ============================================================================
-- Self-test
-- ============================================================================

-- RFC 8032 section 7.1, test 2: a one-byte message
local SELF_TEST = {
	pk = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
	msg = "72",
	sig = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
}

function Crypto:OnEnable()
	Crypto:RunSelfTest()
end

---Runs the self-test in the background work (out of combat, a slice a frame), once a session.
---@param vector table? for the tests: another { pk, msg, sig } in hex; the result stands whatever it was before
function Crypto:RunSelfTest(vector)
	if vector then
		private.selfTest = nil
	end
	vector = vector or SELF_TEST
	local job = Crypto:NewCheck(Crypto:FromHex(vector.pk), Crypto:FromHex(vector.msg), Crypto:FromHex(vector.sig))
	Crypto:Check(job, function(ok)
		-- A signature made before its turn came ran it already (EnsureSelfTest)
		if private.selfTest == nil then
			private.FinishSelfTest(ok)
		end
	end)
end

---Notes the self-test's result. A client whose arithmetic doesn't match RFC 8032 (its doubles round another way,
---say) neither signs nor checks anything this session, and its records follow the rules for unsigned ones.
function private.FinishSelfTest(ok)
	private.selfTest = ok
	private.selfTestText = ok and "passed" or "FAILED: signing and checking are off"
	if ok then
		Wanted:Log("Crypto: self-test passed")
	else
		Wanted:Log("!! Crypto: self-test failed; nothing is signed or checked this session")
		Wanted:NoteProblem("Crypto: the Ed25519 self-test failed; signing and checking are off")
	end
end

---Whether signing and checking are on: the self-test passed. nil while it hasn't run yet.
---@return boolean?
function Crypto:IsOn()
	return private.selfTest
end

---Runs the self-test now, all at once (about 25 ms in the game), if it hasn't run: for a record to sign before its
---turn came. Never in a fight.
---@return boolean ok
function Crypto:EnsureSelfTest()
	if private.selfTest == nil then
		private.FinishSelfTest(verify(Crypto:FromHex(SELF_TEST.pk), Crypto:FromHex(SELF_TEST.msg), Crypto:FromHex(SELF_TEST.sig)))
	end
	return private.selfTest
end

---The self-test's result in words, for /wanted bug.
---@return string
function Crypto:SelfTestText()
	return private.selfTestText
end

function Crypto:Status()
	return "Crypto: self-test "..private.selfTestText.."."
end
