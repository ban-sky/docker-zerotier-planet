/*
 * Pure WebAssembly Argon2 shim for ztncui.
 *
 * ztncui 0.8.14 depends on the native "argon2" package, which needs a C++
 * toolchain at install time and frequently fails on modern Node.js releases.
 * hash-wasm is a dependency-free WebAssembly implementation that supports the
 * same PHC string format, so no native build step is required.
 *
 * GPLv3 - see LICENSE.
 */

const crypto = require('crypto');
const { argon2Verify, argon2id } = require('hash-wasm');

const PARAMS = {
  parallelism: 1,
  iterations: 3,
  memorySize: 65536, // KiB (64 MiB)
  hashLength: 32
};

async function verify(hash, password) {
  if (typeof hash !== 'string' || typeof password !== 'string') return false;
  try {
    return await argon2Verify({ password, hash });
  } catch (err) {
    return false;
  }
}

async function hash(password) {
  if (typeof password !== 'string' || password.length === 0) {
    throw new Error('password must be a non-empty string');
  }
  const salt = crypto.randomBytes(16);
  return argon2id({
    password,
    salt,
    parallelism: PARAMS.parallelism,
    iterations: PARAMS.iterations,
    memorySize: PARAMS.memorySize,
    hashLength: PARAMS.hashLength,
    outputType: 'encoded'
  });
}

module.exports = { verify, hash };
