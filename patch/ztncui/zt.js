/*
  ztncui - ZeroTier network controller UI
  Copyright (C) 2017-2021  Key Networks (https://key-networks.com)
  Licensed under GPLv3 - see LICENSE for details.

  ZeroTier controller client. Uses the built-in Node.js fetch implementation
  instead of the unmaintained got@7 package, and validates IDs before they are
  interpolated into controller URLs.
*/

const token = require('./token');
const { canonicalCidr } = require('../ip');

const ID_RE = /^[0-9a-f]{10,16}$/i;

function controllerBase() {
  let address = process.env.ZT_ADDR || '127.0.0.1:9994';
  if (!/^https?:\/\//i.test(address)) address = 'http://' + address;
  return address.replace(/\/+$/, '');
}

function assertId(value, label) {
  if (!ID_RE.test(String(value || ''))) {
    const err = new Error('Invalid ' + label);
    err.status = 400;
    throw err;
  }
  return String(value);
}

async function request(path, options) {
  const opts = options || {};
  const authToken = await token.get();
  const headers = {
    'X-ZT1-Auth': authToken,
    Accept: 'application/json'
  };
  let body;
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opts.body);
  }

  const response = await fetch(controllerBase() + path, {
    method: opts.method || 'GET',
    headers,
    body,
    signal: AbortSignal.timeout(15000)
  });

  const text = await response.text();
  if (!response.ok) {
    const err = new Error('ZeroTier controller request failed (' + response.status + ' ' + (opts.method || 'GET') + ' ' + path + ')');
    err.statusCode = response.status;
    err.body = text.slice(0, 512);
    throw err;
  }
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error('ZeroTier controller returned invalid JSON');
  }
}

exports.get_zt_status = async function() {
  return request('/status');
};

exports.get_zt_address = async function() {
  return (await exports.get_zt_status()).address;
};

exports.network_list = async function() {
  const nwids = await request('/controller/network');
  if (!Array.isArray(nwids)) return [];
  return Promise.all(nwids.map(async (nwid) => {
    const network = await request('/controller/network/' + assertId(nwid, 'network ID'));
    return { name: network.name, nwid: network.nwid };
  }));
};

exports.network_detail = async function(nwid) {
  return request('/controller/network/' + assertId(nwid, 'network ID'));
};

exports.network_create = async function(network) {
  // ZeroTier 1.16 supports POST /controller/network with a JSON object. The
  // old /<address>______ endpoint is still present but deprecated.
  return request('/controller/network', {
    method: 'POST',
    body: network && network.name !== undefined ? { name: network.name } : network
  });
};

exports.network_delete = async function(nwid) {
  const result = await request('/controller/network/' + assertId(nwid, 'network ID'), { method: 'DELETE' });
  return Object.assign({ deleted: true }, result || {});
};

exports.ipAssignmentPools = async function(nwid, pool, action) {
  const network = await exports.network_detail(nwid);
  let pools = Array.isArray(network.ipAssignmentPools) ? network.ipAssignmentPools.slice() : [];

  if (action === 'add') {
    pools.push(pool);
  } else if (action === 'delete') {
    pools = pools.filter((item) =>
      item.ipRangeStart !== pool.ipRangeStart || item.ipRangeEnd !== pool.ipRangeEnd);
  }

  return request('/controller/network/' + assertId(nwid, 'network ID'), {
    method: 'POST',
    body: { ipAssignmentPools: pools }
  });
};

exports.ipAssignmentDelete = async function(nwid, id, index) {
  const member = await exports.member_detail(nwid, id);
  const assignments = Array.isArray(member.ipAssignments) ? member.ipAssignments.slice() : [];
  const position = Number(index);
  if (!Number.isInteger(position) || position < 0 || position >= assignments.length) {
    throw new Error('Invalid IP assignment index');
  }
  assignments.splice(position, 1);
  const result = await request('/controller/network/' + assertId(nwid, 'network ID') + '/member/' + assertId(id, 'member ID'), {
    method: 'POST',
    body: { ipAssignments: assignments }
  });
  return Object.assign({ deleted: true }, result || {});
};

exports.ipAssignmentAdd = async function(nwid, id, assignment) {
  const member = await exports.member_detail(nwid, id);
  const assignments = Array.isArray(member.ipAssignments) ? member.ipAssignments.slice() : [];
  if (!assignments.includes(assignment.ipAddress)) assignments.push(assignment.ipAddress);
  const result = await request('/controller/network/' + assertId(nwid, 'network ID') + '/member/' + assertId(id, 'member ID'), {
    method: 'POST',
    body: { ipAssignments: assignments }
  });
  return Object.assign({ added: true }, result || {});
};

exports.routes = async function(nwid, route, action) {
  const network = await exports.network_detail(nwid);
  let routes = Array.isArray(network.routes) ? network.routes.slice() : [];
  const canonical = canonicalCidr(route.target);
  const existing = routes.find((item) => canonicalCidr(item.target) === canonical);

  if (!existing && action === 'add') {
    routes.push({ target: canonical, via: route.via || null });
  } else if (existing && action === 'delete') {
    routes = routes.filter((item) => item !== existing);
  } else if (!existing && action === 'delete') {
    throw new Error('Cannot delete non-existent route target');
  } else {
    throw new Error('Route target is not unique');
  }

  return request('/controller/network/' + assertId(nwid, 'network ID'), {
    method: 'POST',
    body: { routes }
  });
};

exports.network_object = async function(nwid, object) {
  return request('/controller/network/' + assertId(nwid, 'network ID'), {
    method: 'POST',
    body: object
  });
};

exports.members = async function(nwid) {
  return request('/controller/network/' + assertId(nwid, 'network ID') + '/member');
};

exports.member_detail = async function(nwid, id) {
  return request('/controller/network/' + assertId(nwid, 'network ID') + '/member/' + assertId(id, 'member ID'));
};

exports.member_object = async function(nwid, id, object) {
  return request('/controller/network/' + assertId(nwid, 'network ID') + '/member/' + assertId(id, 'member ID'), {
    method: 'POST',
    body: object
  });
};

exports.member_delete = async function(nwid, id) {
  const result = await request('/controller/network/' + assertId(nwid, 'network ID') + '/member/' + assertId(id, 'member ID'), { method: 'DELETE' });
  return Object.assign({ deleted: true }, result || {});
};

exports.network_easy_setup = async function(nwid, routes, ipAssignmentPools, v4AssignMode) {
  return request('/controller/network/' + assertId(nwid, 'network ID'), {
    method: 'POST',
    body: {
      ipAssignmentPools,
      routes,
      v4AssignMode
    }
  });
};

exports.peers = async function() {
  return request('/peer');
};

exports.peer = async function(id) {
  try {
    return await request('/peer/' + assertId(id, 'peer ID'));
  } catch (err) {
    if (err.statusCode === 404) return null;
    throw err;
  }
};
