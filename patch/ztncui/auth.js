/*
  ztncui - ZeroTier network controller UI
  Copyright (C) 2017-2021  Key Networks (https://key-networks.com)
  Licensed under GPLv3 - see LICENSE for details.
*/

const argon2 = require('../argon2-wasm');
const usersController = require('../controllers/usersController');

// A fixed PHC hash used to keep the timing of "unknown user" close to the
// timing of a real password check. The password is irrelevant because the
// result is discarded.
const DUMMY_HASH = '$argon2id$v=19$m=65536,t=3,p=1$wbq59GJdrmDhiQN7O4ASUA$kuVVAufv6VusWm3/dS4AiCkNR6RLzgAMOAn1/np6Co4';

const hash_check = async function(user, password) {
  const users = await usersController.get_users();

  if (!Object.prototype.hasOwnProperty.call(users, user)) {
    // Equalize timing and never index the prototype chain (e.g. "constructor").
    await argon2.verify(DUMMY_HASH, password).catch(() => false);
    return false;
  }

  const record = users[user];
  if (!record || typeof record.hash !== 'string') return false;

  return argon2.verify(record.hash, password).catch(() => false);
};

exports.authenticate = async function(name, pass, callback) {
  if (typeof name !== 'string' || typeof pass !== 'string' || !name || !pass) {
    return callback(new Error('invalid credentials'));
  }

  let users;
  try {
    users = await usersController.get_users();
  } catch (err) {
    throw err;
  }

  if (!Object.prototype.hasOwnProperty.call(users, name)) {
    await hash_check(name, pass);
    return callback(new Error('invalid credentials'));
  }

  const user = users[name];
  const verified = await hash_check(name, pass);
  if (verified) {
    // Do not put the password hash into the session.
    return callback(null, { name: user.name, pass_set: !!user.pass_set });
  }
  return callback(new Error('invalid credentials'));
};

exports.restrict = function(req, res, next) {
  if (req.session.user) {
    next();
  } else {
    req.session.error = 'Access denied!';
    res.redirect('/login?redirect=' + encodeURIComponent(req.originalUrl));
  }
};
