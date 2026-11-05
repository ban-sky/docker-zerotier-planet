#!/usr/bin/env node
/*
 * Fill in the stableEndpoints of a ZeroTier moon definition.
 *
 * `zerotier-idtool initmoon` emits an empty endpoint list; the moon must list
 * at least one reachable "IP/port" tuple or clients cannot use it. Hostnames
 * are resolved to addresses because moon files only accept IP literals.
 *
 * The moon JSON contains the moon's signing secret, so it is written with mode
 * 0600 and never copied into the public dist directory.
 *
 * GPLv3 - see LICENSE.
 */

'use strict';

const dns = require('dns');
const fs = require('fs');
const net = require('net');
const path = require('path');

function usage() {
  console.error('usage: configure-moon.js --moon <moon.json> --port <port> [--ipv4 <addr>] [--ipv6 <addr>]');
  process.exit(2);
}

function parseArgs(argv) {
  const out = { moon: '', port: 9994, ipv4: '', ipv6: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) usage();
      return argv[(i += 1)];
    };
    switch (arg) {
      case '--moon': out.moon = next(); break;
      case '--port': out.port = parseInt(next(), 10); break;
      case '--ipv4': out.ipv4 = next(); break;
      case '--ipv6': out.ipv6 = next(); break;
      case '-h':
      case '--help': usage(); break;
      default: usage();
    }
  }
  return out;
}

function resolveAddress(value, family) {
  return new Promise((resolve, reject) => {
    if (net.isIP(value)) {
      if (net.isIP(value) !== family) {
        return reject(new Error('address family mismatch for ' + value));
      }
      return resolve(value);
    }
    dns.lookup(value, { family }, (err, address) => {
      if (err) return reject(new Error('cannot resolve ' + value + ': ' + err.message));
      if (!net.isIP(address) || net.isIP(address) !== family) {
        return reject(new Error(value + ' did not resolve to an IPv' + family + ' address'));
      }
      resolve(address);
    });
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.moon) usage();
  if (!Number.isInteger(args.port) || args.port < 1 || args.port > 65535) {
    throw new Error('invalid port');
  }

  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(args.moon, 'utf8'));
  } catch (err) {
    throw new Error('cannot read moon file: ' + err.message);
  }
  if (!doc || doc.worldType !== 'moon' || !Array.isArray(doc.roots) || doc.roots.length === 0) {
    throw new Error('moon file has an unexpected structure');
  }

  const endpoints = [];
  if (args.ipv4) endpoints.push((await resolveAddress(args.ipv4, 4)) + '/' + args.port);
  if (args.ipv6) endpoints.push((await resolveAddress(args.ipv6, 6)) + '/' + args.port);

  if (endpoints.length === 0) {
    throw new Error('at least one of --ipv4/--ipv6 is required');
  }

  doc.roots[0].stableEndpoints = endpoints;

  const tmp = path.resolve(args.moon) + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, path.resolve(args.moon));
  fs.chmodSync(path.resolve(args.moon), 0o600);
  console.log('configure-moon: endpoints ' + endpoints.join(', '));
}

main().catch((err) => {
  console.error('configure-moon: ' + err.message);
  process.exit(1);
});
