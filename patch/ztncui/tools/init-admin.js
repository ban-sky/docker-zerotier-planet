#!/usr/bin/env node
/*
 * First-boot bootstrap for the ztncui admin account.
 *
 * Creates a random admin password instead of shipping the well-known
 * "admin/password" default. The password is written to a 0600 file and the
 * account is marked "pass_set": false, so ztncui forces a password change on
 * the first login. After that change the password file is removed by
 * usersController.
 *
 * GPLv3 - see LICENSE.
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const argon2 = require('../argon2-wasm');

const PASSWD = path.resolve(process.env.ZTNCUI_PASSWD || '/app/config/ztncui-passwd');
const PASSWORD_FILE = path.resolve(process.env.ZTNCUI_ADMIN_PASSWORD_FILE || '/app/config/admin-password');

function fail(message) {
  console.error('init-admin: ' + message);
  process.exit(1);
}

function existingUsers() {
  try {
    const raw = fs.readFileSync(PASSWD, 'utf8');
    const data = JSON.parse(raw);
    if (data && typeof data === 'object' && Object.keys(data).length > 0) return data;
  } catch (err) {
    if (err.code !== 'ENOENT') fail('cannot read ' + PASSWD + ': ' + err.message);
  }
  return null;
}

function atomicWrite(file, data, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, data, { encoding: 'utf8', mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, file);
  fs.chmodSync(file, mode);
}

async function main() {
  if (existingUsers()) {
    console.log('init-admin: existing admin database found, leaving it untouched');
    return;
  }

  // 18 random bytes -> 24 base64url characters, well above the 10 char minimum.
  const password = crypto.randomBytes(18).toString('base64url');
  const hash = await argon2.hash(password);

  const users = { admin: { name: 'admin', pass_set: false, hash } };
  atomicWrite(PASSWD, JSON.stringify(users), 0o600);
  atomicWrite(PASSWORD_FILE,
    'ztncui initial admin credentials\n' +
    'username: admin\n' +
    'password: ' + password + '\n\n' +
    'You must change this password on first login.\n' +
    'This file is deleted automatically after the password is changed.\n',
    0o600);

  console.log('init-admin: created admin user with a random one-time password');
  console.log('init-admin: the password is stored in ' + PASSWORD_FILE + ' (mode 0600)');
}

main().catch((err) => fail(err.message));
