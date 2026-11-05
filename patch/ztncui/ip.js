/*
  IP address helpers used by the ztncui overlay.

  Replaces the unmaintained `ip-address` package with the Node.js `net`
  module plus BigInt subnet arithmetic. Only the operations ztncui needs are
  implemented, which keeps the dependency surface small.
*/

const net = require('node:net');

function version(value) {
  return net.isIP(String(value == null ? '' : value));
}

function isIP(value, family) {
  const v = version(value);
  if (family === 4) return v === 4;
  if (family === 6) return v === 6;
  return v !== 0;
}

function canonicalIPv6(address) {
  // WHATWG URL parsing performs RFC 5952 canonicalisation for us.
  return new URL('http://[' + address + ']/').hostname.slice(1, -1);
}

function ipv4ToBigInt(address) {
  return address.split('.').reduce((acc, part) => (acc << 8n) + BigInt(part), 0n);
}

function ipv6ToBigInt(address) {
  const canonical = canonicalIPv6(address);
  const halves = canonical.split('::');
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length > 1 && halves[1] ? halves[1].split(':') : [];
  const groups = left.concat(Array(8 - left.length - right.length).fill('0'), right);
  return groups.reduce((acc, group) => (acc << 16n) + BigInt(parseInt(group, 16)), 0n);
}

function parseCidr(cidr) {
  if (typeof cidr !== 'string') return null;
  const parts = cidr.split('/');
  if (parts.length !== 2 || !/^\d{1,3}$/.test(parts[1])) return null;
  const v = version(parts[0]);
  if (!v) return null;
  const prefix = Number(parts[1]);
  if (prefix < 0 || prefix > (v === 4 ? 32 : 128)) return null;
  return { address: parts[0], version: v, prefix };
}

function canonicalCidr(cidr) {
  const parsed = parseCidr(cidr);
  if (!parsed) return cidr;
  const address = parsed.version === 6 ? canonicalIPv6(parsed.address) : parsed.address;
  return address + '/' + parsed.prefix;
}

function isValidCidr(cidr, maxPrefix, family) {
  const parsed = parseCidr(cidr);
  if (!parsed) return false;
  if (family && parsed.version !== family) return false;
  if (maxPrefix !== undefined && parsed.prefix > maxPrefix) return false;
  return true;
}

function ipInCidr(ip, cidr) {
  const parsed = parseCidr(cidr);
  if (!parsed || version(ip) !== parsed.version) return false;
  const bits = parsed.version === 4 ? 32 : 128;
  const value = parsed.version === 4 ? ipv4ToBigInt(ip) : ipv6ToBigInt(ip);
  const network = parsed.version === 4
    ? ipv4ToBigInt(parsed.address)
    : ipv6ToBigInt(parsed.address);
  const shift = BigInt(bits - parsed.prefix);
  return (value >> shift) === (network >> shift);
}

module.exports = {
  isIP,
  isValidCidr,
  canonicalCidr,
  ipInCidr,
  version
};
