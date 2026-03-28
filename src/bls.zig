const std = @import("std");
const c = @cImport(@cInclude("blst.h"));

pub const Error = error{
    BadEncoding,
    PointNotOnCurve,
    PointNotInGroup,
    VerifyFail,
    PkIsInfinity,
    BadScalar,
    Unknown,
};

fn mapError(err: c.BLST_ERROR) Error {
    return switch (err) {
        c.BLST_BAD_ENCODING => Error.BadEncoding,
        c.BLST_POINT_NOT_ON_CURVE => Error.PointNotOnCurve,
        c.BLST_POINT_NOT_IN_GROUP => Error.PointNotInGroup,
        c.BLST_VERIFY_FAIL => Error.VerifyFail,
        c.BLST_PK_IS_INFINITY => Error.PkIsInfinity,
        c.BLST_BAD_SCALAR => Error.BadScalar,
        else => Error.Unknown,
    };
}

// IC certificate BLS domain separator: length byte + "ic-state-root"
const IC_STATE_ROOT_DOMAIN_SEP = "\x0dic-state-root";

// BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_
const DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

// DER prefix for IC BLS public keys.
const DER_PREFIX: *const [37]u8 = "\x30\x81\x82\x30\x1d\x06\x0d\x2b\x06\x01\x04\x01\x82\xdc\x7c\x05\x03\x01\x02\x01\x06\x0c\x2b\x06\x01\x04\x01\x82\xdc\x7c\x05\x03\x02\x01\x03\x61\x00";

pub fn extractDerKey(der_key: []const u8) error{InvalidDerKey}![]const u8 {
    if (der_key.len != 37 + 96) return error.InvalidDerKey;
    if (!std.mem.eql(u8, der_key[0..37], DER_PREFIX)) return error.InvalidDerKey;
    return der_key[37..];
}

// Verify a BLS12-381 signature (min_sig: G1 signatures, G2 public keys).
pub fn verify(sig_bytes: []const u8, msg: []const u8, pk_bytes: []const u8) Error!void {
    if (sig_bytes.len != 48) return Error.BadEncoding;
    if (pk_bytes.len != 96) return Error.BadEncoding;

    var sig: c.blst_p1_affine = undefined;
    const sig_err = c.blst_p1_uncompress(&sig, sig_bytes.ptr);
    if (sig_err != c.BLST_SUCCESS) return mapError(sig_err);

    var pk: c.blst_p2_affine = undefined;
    const pk_err = c.blst_p2_uncompress(&pk, pk_bytes.ptr);
    if (pk_err != c.BLST_SUCCESS) return mapError(pk_err);

    const result = c.blst_core_verify_pk_in_g2(
        &pk,
        &sig,
        true, // hash (RO mode, not encode)
        msg.ptr,
        msg.len,
        DST,
        DST.len,
        null, // no augmentation (NUL_)
        0,
    );
    if (result != c.BLST_SUCCESS) return mapError(result);
}

// Verify an IC state root certificate signature.
// The signed message is domain_sep("ic-state-root") || root_hash.
pub fn verifyIcCertificate(
    sig_bytes: []const u8,
    root_hash: *const [32]u8,
    pk_bytes: []const u8,
) Error!void {
    var msg: [IC_STATE_ROOT_DOMAIN_SEP.len + 32]u8 = undefined;
    @memcpy(msg[0..IC_STATE_ROOT_DOMAIN_SEP.len], IC_STATE_ROOT_DOMAIN_SEP);
    @memcpy(msg[IC_STATE_ROOT_DOMAIN_SEP.len..], root_hash);
    return verify(sig_bytes, &msg, pk_bytes);
}

// Test vectors from ic-verify-bls-signature crate.
const tv1_sig = &@as([48]u8, @bitCast(@as(*const [48]u8, "\xac\xe9\xfc\xdd\x9b\xc9\x77\xe0\x5d\x63\x28\xf8\x89\xdc\x4e\x7c\x99\x11\x4c\x73\x7a\x49\x46\x53\xcb\x27\xa1\xf5\x5c\x06\xf4\x55\x5e\x0f\x16\x09\x80\xaf\x5e\xad\x09\x8a\xcc\x19\x50\x10\xb2\xf7").*));
const tv1_msg = &@as([46]u8, @bitCast(@as(*const [46]u8, "\x0d\x69\x63\x2d\x73\x74\x61\x74\x65\x2d\x72\x6f\x6f\x74\xe6\xc0\x1e\x90\x9b\x49\x23\x34\x5c\xe5\x97\x09\x62\xbc\xfe\x30\x04\xbf\xd8\x47\x4a\x21\xda\xe2\x8f\x50\x69\x25\x02\xf4\x6d\x90").*));
const tv1_key = &@as([96]u8, @bitCast(@as(*const [96]u8, "\x81\x4c\x0e\x6e\xc7\x1f\xab\x58\x3b\x08\xbd\x81\x37\x3c\x25\x5c\x3c\x37\x1b\x2e\x84\x86\x3c\x98\xa4\xf1\xe0\x8b\x74\x23\x5d\x14\xfb\x5d\x9c\x0c\xd5\x46\xd9\x68\x5f\x91\x3a\x0c\x0b\x2c\xc5\x34\x15\x83\xbf\x4b\x43\x92\xe4\x67\xdb\x96\xd6\x5b\x9b\xb4\xcb\x71\x71\x12\xf8\x47\x2e\x0d\x5a\x4d\x14\x50\x5f\xfd\x74\x84\xb0\x12\x91\x09\x1c\x5f\x87\xb9\x88\x83\x46\x3f\x98\x09\x1a\x0b\xaa\xae").*));

const tv2_sig = &@as([48]u8, @bitCast(@as(*const [48]u8, "\x89\xa2\xbe\x21\xb5\xfa\x8a\xc9\xfa\xb1\x52\x7e\x04\x13\x27\xce\x89\x9d\x7d\xa9\x71\x43\x6a\x1f\x21\x65\x39\x39\x47\xb4\xd9\x42\x36\x5b\xfe\x54\x88\x71\x0e\x61\xa6\x19\xba\x48\x38\x8a\x21\xb1").*));
const tv2_msg = &@as([46]u8, @bitCast(@as(*const [46]u8, "\x0d\x69\x63\x2d\x73\x74\x61\x74\x65\x2d\x72\x6f\x6f\x74\xb2\x94\xb4\x18\xb1\x1e\xbe\x5d\xd7\xdd\x1d\xcb\x09\x9e\x4e\x03\x72\xb9\xa4\x2a\xef\x7a\x7a\x37\xfb\x4f\x25\x66\x7d\x70\x5e\xa9").*));
const tv2_key = &@as([96]u8, @bitCast(@as(*const [96]u8, "\x99\x33\xe1\xf8\x9e\x8a\x3c\x4d\x7f\xdc\xcc\xdb\xd5\x18\x08\x9e\x2b\xd4\xd8\x18\x0a\x26\x1f\x18\xd9\xc2\x47\xa5\x27\x68\xeb\xce\x98\xdc\x73\x28\xa3\x98\x14\xa8\xf9\x11\x08\x6a\x1d\xd5\x0c\xbe\x01\x5e\x2a\x53\xb7\xbf\x78\xb5\x52\x88\x89\x3d\xaa\x15\xc3\x46\x64\x0e\x88\x31\xd7\x2a\x12\xbd\xed\xd9\x79\xd2\x84\x70\xc3\x48\x23\xb8\xd1\xc3\xf4\x79\x5d\x9c\x39\x84\xa2\x47\x13\x2e\x94\xfe").*));

test "verify valid ic signature" {
    try verify(tv1_sig, tv1_msg, tv1_key);
}

test "verify second valid ic signature" {
    try verify(tv2_sig, tv2_msg, tv2_key);
}

test "reject mismatched sig/msg" {
    // sig2 with msg1/key1 should fail
    try std.testing.expectError(Error.VerifyFail, verify(tv2_sig, tv1_msg, tv1_key));
}

test "verify certificate message format" {
    const root_hash: [32]u8 = tv1_msg[IC_STATE_ROOT_DOMAIN_SEP.len..].*;
    var msg: [IC_STATE_ROOT_DOMAIN_SEP.len + 32]u8 = undefined;
    @memcpy(msg[0..IC_STATE_ROOT_DOMAIN_SEP.len], IC_STATE_ROOT_DOMAIN_SEP);
    @memcpy(msg[IC_STATE_ROOT_DOMAIN_SEP.len..], &root_hash);
    try std.testing.expectEqualSlices(u8, tv1_msg, &msg);
}
