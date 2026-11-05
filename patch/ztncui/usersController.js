/*
  ztncui - ZeroTier network controller UI
  Copyright (C) 2017-2021  Key Networks (https://key-networks.com)
  Licensed under GPLv3 - see LICENSE for details.

  Hardened user/password controller:
  - password file is configurable and outside the application directory
  - atomic writes with 0600 permissions
  - username lookups never traverse the prototype chain
  - existing admin passwords can only be changed by that admin
  - the bootstrap password file is removed after the first password change
*/

const fs = require('fs');
const path = require('path');
const util = require('util');
const argon2 = require('../argon2-wasm');

const passwd_file = process.env.ZTNCUI_PASSWD
  ? path.resolve(process.env.ZTNCUI_PASSWD)
  : path.join(__dirname, '..', 'etc', 'passwd');
const admin_password_file = process.env.ZTNCUI_ADMIN_PASSWORD_FILE || '';
const min_pass_len = 10;
const max_pass_len = 160;
const username_re = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const reserved_names = new Set(['__proto__', 'prototype', 'constructor', 'hasOwnProperty']);

const readFile = util.promisify(fs.readFile);
const writeFile = util.promisify(fs.writeFile);
const chmod = util.promisify(fs.chmod);
const rename = util.promisify(fs.rename);
const mkdir = util.promisify(fs.mkdir);
const unlink = util.promisify(fs.unlink);

let _users = null;

function validUsername(name) {
  return typeof name === 'string' && username_re.test(name) && !reserved_names.has(name);
}

const get_users = async function() {
  if (_users) return _users;
  _users = JSON.parse(await readFile(passwd_file, 'utf8'));
  return _users;
};
exports.get_users = get_users;

const update_users = async function(users) {
  await mkdir(path.dirname(passwd_file), { recursive: true, mode: 0o700 });
  const tmp = passwd_file + '.tmp-' + process.pid;
  await writeFile(tmp, JSON.stringify(users), { encoding: 'utf8', mode: 0o600 });
  await chmod(tmp, 0o600);
  await rename(tmp, passwd_file);
  await chmod(passwd_file, 0o600);
  _users = null;
  return await get_users();
};

function removeBootstrapPassword() {
  if (!admin_password_file) return;
  unlink(admin_password_file).catch(() => {});
}

exports.users_list = async function(req, res) {
  const navigate = { active: 'users' };
  try {
    const users = await get_users();
    const list = Object.keys(users).map((name) => ({ name, pass_set: !!users[name].pass_set }));
    res.render('users', { title: 'Admin users', navigate, message: 'List of users with admin privileges', users: list });
  } catch (err) {
    res.status(500).render('users', {
      title: 'Admin users',
      navigate,
      message: 'Error',
      users: null,
      error: 'Error returning list of users'
    });
  }
};

exports.password_get = async function(req, res) {
  const navigate = { active: 'users' };
  const target = req.params.name;
  const sessionUser = req.session.user && req.session.user.name;

  if (!validUsername(target)) {
    return res.status(400).render('error', { message: 'Invalid username', error: {} });
  }

  let users;
  try {
    users = await get_users();
  } catch (err) {
    throw err;
  }

  const existing = Object.prototype.hasOwnProperty.call(users, target) ? users[target] : null;
  if (existing && existing.pass_set && target !== sessionUser) {
    return res.status(403).render('error', { message: 'You may only change your own password', error: {} });
  }

  const user = { name: target, password1: null, password2: null };
  res.render('password', {
    title: 'Set password',
    navigate,
    user,
    readonly: true,
    message: ''
  });
};

exports.password_post = async function(req, res) {
  const navigate = { active: 'users' };
  const target = req.params.name;
  const sessionUser = req.session.user && req.session.user.name;

  if (!validUsername(target)) {
    return res.status(400).render('error', { message: 'Invalid username', error: {} });
  }

  let users;
  try {
    users = await get_users();
  } catch (err) {
    throw err;
  }

  const existing = Object.prototype.hasOwnProperty.call(users, target) ? users[target] : null;
  if (existing && existing.pass_set && target !== sessionUser) {
    return res.status(403).render('error', { message: 'You may only change your own password', error: {} });
  }

  req.checkBody('password1', 'Password required').notEmpty();
  req.checkBody('password1', 'Minimum password length is ' + min_pass_len + ' characters')
    .isLength({ min: min_pass_len, max: max_pass_len });
  req.checkBody('password2', 'Please re-enter password').notEmpty();
  req.checkBody('password2', 'Passwords are not the same').equals(req.body.password1);

  const errors = req.validationErrors();
  if (errors) {
    return res.status(400).render('password', {
      title: 'Set password',
      navigate,
      user: { name: target, password1: null, password2: null },
      readonly: true,
      message: 'Please check errors below',
      errors
    });
  }

  let pass_set = true;
  if (req.body.pass_set === 'check') pass_set = false;

  const hash = await argon2.hash(req.body.password1);
  users[target] = { name: target, pass_set, hash };
  await update_users(users);

  if (pass_set && target === sessionUser) {
    // The bootstrap password is useless after the admin has chosen a new one.
    removeBootstrapPassword();
  }

  res.render('password', {
    title: 'Set password',
    navigate,
    user: { name: target },
    readonly: true,
    message: 'Successfully set password for ' + target
  });
};

exports.user_create_get = async function(req, res) {
  const navigate = { active: 'create_user' };
  res.render('password', {
    title: 'Create new admin user',
    navigate,
    user: { name: null, password1: null, password2: null },
    readonly: false,
    message: ''
  });
};

exports.user_create_post = async function(req, res) {
  const navigate = { active: 'create_user' };
  const name = typeof req.body.username === 'string' ? req.body.username.trim() : '';

  if (!validUsername(name)) {
    return res.status(400).render('password', {
      title: 'Create new admin user',
      navigate,
      user: { name, password1: null, password2: null },
      readonly: false,
      message: 'Username must be 1-64 characters: letters, digits, dot, underscore or dash'
    });
  }

  let users;
  try {
    users = await get_users();
  } catch (err) {
    throw err;
  }
  if (Object.prototype.hasOwnProperty.call(users, name)) {
    return res.status(409).render('password', {
      title: 'Create new admin user',
      navigate,
      user: { name, password1: null, password2: null },
      readonly: false,
      message: 'A user with that name already exists'
    });
  }

  // Keep the original 307 flow: the password is submitted by the next form.
  res.redirect(307, '/users/' + encodeURIComponent(name) + '/password');
};

exports.user_delete_get = async function(req, res) {
  const navigate = { active: 'users' };
  const target = req.params.name;

  let users;
  try {
    users = await get_users();
  } catch (err) {
    throw err;
  }

  const user = Object.prototype.hasOwnProperty.call(users, target) ? users[target] : null;
  if (!user) {
    return res.status(404).render('user_delete', { title: 'Delete user', navigate, user: null });
  }
  if (req.session.user && req.session.user.name === target) {
    return res.status(400).render('user_delete', {
      title: 'Delete user',
      navigate,
      user,
      self_delete: true
    });
  }

  res.render('user_delete', { title: 'Delete user', navigate, user });
};

exports.user_delete_post = async function(req, res) {
  const navigate = { active: 'users' };
  const target = req.params.name;

  if (req.body.delete !== 'delete') {
    return res.redirect('/users');
  }

  let users;
  try {
    users = await get_users();
  } catch (err) {
    throw err;
  }

  const user = Object.prototype.hasOwnProperty.call(users, target) ? users[target] : null;
  if (!user) {
    return res.status(404).render('user_delete', { title: 'Delete user', navigate, user: null });
  }
  if (req.session.user && req.session.user.name === target) {
    return res.status(400).render('user_delete', {
      title: 'Delete user',
      navigate,
      user,
      self_delete: true
    });
  }
  if (Object.keys(users).length <= 1) {
    return res.status(400).render('user_delete', {
      title: 'Delete user',
      navigate,
      user,
      errors: [{ msg: 'The last admin user cannot be deleted' }]
    });
  }

  delete users[target];
  await update_users(users);

  res.render('user_delete', {
    title: 'Deleted user',
    navigate,
    user: { name: target },
    deleted: true
  });
};
