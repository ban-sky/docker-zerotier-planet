/*
 * mkworld for ZeroTier One 1.16.x
 *
 * Copyright (C) 2011-2026 ZeroTier, Inc. (original mkworld)
 * Copyright (C) 2026 ban-sky (adaptation to the ECC / header-only World API)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * ---------------------------------------------------------------------------
 * This tool builds a signed planet (world.bin) for a private ZeroTier
 * network controller.
 *
 * ZeroTier 1.16 replaced C25519 key pairs with ECC key pairs (64 byte public
 * key + 64 byte private key) and removed attic/world. World is now a
 * header-only class in node/World.hpp. The signing key is read from a normal
 * ZeroTier identity.secret file, so no extra key files are required.
 *
 * Example:
 *   mkworld --identity identity.secret --moon moon.json --output planet
 */

#include <nlohmann/json.hpp>

#include <node/Constants.hpp>
#include <node/ECC.hpp>
#include <node/Identity.hpp>
#include <node/InetAddress.hpp>
#include <node/World.hpp>
#include <osdep/OSUtils.hpp>

#include <sys/stat.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using namespace ZeroTier;

namespace {

void usage(const char* argv0)
{
	std::fprintf(stderr,
		"Usage: %s [options]\n"
		"\n"
		"Options:\n"
		"  -i, --identity <file>   identity.secret containing the signing key (default: identity.secret)\n"
		"  -m, --moon <file>       moon.json with roots and stableEndpoints (default: moon.json)\n"
		"  -o, --output <file>     output planet file (default: world.bin)\n"
		"  -t, --timestamp <ms>    world timestamp in milliseconds (default: current time)\n"
		"  -w, --world-id <id>     world ID (default: %llu, Earth)\n"
		"  -d, --dump <file>       print a planet file as JSON and exit\n"
		"  -h, --help              show this help\n",
		argv0, (unsigned long long)ZT_WORLD_ID_EARTH);
}

bool readTextFile(const std::string& path, std::string& out)
{
	if (!OSUtils::readFile(path.c_str(), out)) {
		std::fprintf(stderr, "ERROR: cannot read %s\n", path.c_str());
		return false;
	}
	return true;
}

uint64_t parseU64(const char* s, bool& ok)
{
	char* end = nullptr;
	errno = 0;
	const unsigned long long v = std::strtoull(s, &end, 10);
	ok = (errno == 0) && end && (*end == '\0');
	return (uint64_t)v;
}

int makeWorld(const std::string& identityPath, const std::string& moonPath, const std::string& outputPath,
	uint64_t timestamp, uint64_t worldId)
{
	std::string idser;
	if (!readTextFile(identityPath, idser)) {
		return 1;
	}

	Identity id;
	if (!id.fromString(idser.c_str())) {
		std::fprintf(stderr, "ERROR: %s is not a valid ZeroTier identity\n", identityPath.c_str());
		return 1;
	}
	if (!id.hasPrivate()) {
		std::fprintf(stderr, "ERROR: %s does not contain a private key\n", identityPath.c_str());
		return 1;
	}
	if (!id.locallyValidate()) {
		std::fprintf(stderr, "ERROR: identity in %s failed local validation\n", identityPath.c_str());
		return 1;
	}

	std::string moonJson;
	if (!readTextFile(moonPath, moonJson)) {
		return 1;
	}

	nlohmann::json config;
	try {
		config = nlohmann::json::parse(moonJson);
	}
	catch (const std::exception& e) {
		std::fprintf(stderr, "ERROR: cannot parse %s: %s\n", moonPath.c_str(), e.what());
		return 1;
	}

	if (!config.contains("roots") || !config["roots"].is_array() || config["roots"].empty()) {
		std::fprintf(stderr, "ERROR: %s has no roots[] array\n", moonPath.c_str());
		return 1;
	}

	std::vector<World::Root> roots;
	for (const auto& root : config["roots"]) {
		if (!root.contains("identity") || !root["identity"].is_string()) {
			std::fprintf(stderr, "ERROR: root entry has no identity string\n");
			return 1;
		}

		World::Root r;
		if (!r.identity.fromString(root["identity"].get<std::string>().c_str())) {
			std::fprintf(stderr, "ERROR: root identity is invalid\n");
			return 1;
		}
		if (!r.identity.locallyValidate()) {
			std::fprintf(stderr, "ERROR: root identity failed local validation\n");
			return 1;
		}

		if (root.contains("stableEndpoints")) {
			if (!root["stableEndpoints"].is_array()) {
				std::fprintf(stderr, "ERROR: stableEndpoints must be an array\n");
				return 1;
			}
			for (const auto& ep : root["stableEndpoints"]) {
				if (!ep.is_string()) {
					std::fprintf(stderr, "ERROR: stableEndpoints entries must be strings\n");
					return 1;
				}
				InetAddress addr;
				if (!addr.fromString(ep.get<std::string>().c_str()) || (!addr.isV4() && !addr.isV6())) {
					std::fprintf(stderr, "ERROR: invalid stable endpoint: %s\n", ep.get<std::string>().c_str());
					return 1;
				}
				r.stableEndpoints.push_back(addr);
			}
		}

		roots.push_back(r);
	}

	if (roots.size() > ZT_WORLD_MAX_ROOTS) {
		std::fprintf(stderr, "ERROR: too many roots (%zu, max %d)\n", roots.size(), ZT_WORLD_MAX_ROOTS);
		return 1;
	}

	// The root identity also signs this planet. Keeping the identity and the
	// world signing key the same means there is only one secret to protect,
	// and the planet can be re-signed after a restore.
	const ECC::Pair signingKey = id.privateKeyPair();
	const ECC::Public updatesKey = id.publicKey();

	std::fprintf(stderr, "INFO: building planet id=%llu ts=%llu roots=%zu\n",
		(unsigned long long)worldId, (unsigned long long)timestamp, roots.size());

	World world = World::make(World::TYPE_PLANET, worldId, timestamp, updatesKey, roots, signingKey);

	Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> out;
	world.serialize(out, false);

	// Round-trip check: never ship a planet that cannot be parsed.
	World check;
	try {
		check.deserialize(out, 0);
	}
	catch (const std::exception& e) {
		std::fprintf(stderr, "ERROR: generated planet failed to deserialize: %s\n", e.what());
		return 1;
	}
	if (!(check == world)) {
		std::fprintf(stderr, "ERROR: generated planet failed the round-trip check\n");
		return 1;
	}

	// deserialize() only parses; verify the signature explicitly so a build
	// with a broken signing key can never produce an unusable planet.
	Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> signedPart;
	world.serialize(signedPart, true);
	if (!ECC::verify(updatesKey, signedPart.data(), signedPart.size(), world.signature().data)) {
		std::fprintf(stderr, "ERROR: generated planet signature does not verify\n");
		return 1;
	}

	const std::string bytes((const char*)out.data(), out.size());
	if (!OSUtils::writeFile(outputPath.c_str(), bytes)) {
		std::fprintf(stderr, "ERROR: cannot write %s\n", outputPath.c_str());
		return 1;
	}
	(void)::chmod(outputPath.c_str(), 0644);

	std::fprintf(stderr, "INFO: wrote %s (%u bytes)\n", outputPath.c_str(), out.size());
	return 0;
}

int dumpWorld(const std::string& path)
{
	std::string bin;
	if (!readTextFile(path, bin)) {
		return 1;
	}

	try {
		Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> buf(bin.data(), bin.size());
		World world;
		if (!world.deserialize(buf, 0)) {
			std::fprintf(stderr, "ERROR: cannot deserialize %s\n", path.c_str());
			return 1;
		}

		nlohmann::json j;
		j["id"] = world.id();
		j["timestamp"] = world.timestamp();
		j["type"] = (world.type() == World::TYPE_PLANET) ? "planet" : "moon";
		j["roots"] = nlohmann::json::array();
		for (const auto& root : world.roots()) {
			nlohmann::json r;
			char idbuf[ZT_IDENTITY_STRING_BUFFER_LENGTH];
			r["identity"] = root.identity.toString(false, idbuf);
			r["stableEndpoints"] = nlohmann::json::array();
			for (const auto& ep : root.stableEndpoints) {
				char epbuf[64];
				r["stableEndpoints"].push_back(ep.toString(epbuf));
			}
			j["roots"].push_back(r);
		}
		std::cout << j.dump(2) << std::endl;
		return 0;
	}
	catch (const std::exception& e) {
		std::fprintf(stderr, "ERROR: %s\n", e.what());
		return 1;
	}
}

}	// namespace

int main(int argc, char** argv)
{
	std::string identityPath = "identity.secret";
	std::string moonPath = "moon.json";
	std::string outputPath = "world.bin";
	std::string dumpPath;
	uint64_t timestamp = 0;
	uint64_t worldId = ZT_WORLD_ID_EARTH;

	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		auto next = [&](const char* opt) -> const char* {
			if (i + 1 >= argc) {
				std::fprintf(stderr, "ERROR: %s requires an argument\n", opt);
				std::exit(2);
			}
			return argv[++i];
		};

		if (a == "-h" || a == "--help") {
			usage(argv[0]);
			return 0;
		}
		else if (a == "-i" || a == "--identity") {
			identityPath = next(a.c_str());
		}
		else if (a == "-m" || a == "--moon") {
			moonPath = next(a.c_str());
		}
		else if (a == "-o" || a == "--output") {
			outputPath = next(a.c_str());
		}
		else if (a == "-d" || a == "--dump") {
			dumpPath = next(a.c_str());
		}
		else if (a == "-t" || a == "--timestamp") {
			bool ok = false;
			timestamp = parseU64(next(a.c_str()), ok);
			if (!ok || timestamp == 0) {
				std::fprintf(stderr, "ERROR: invalid timestamp\n");
				return 2;
			}
		}
		else if (a == "-w" || a == "--world-id") {
			bool ok = false;
			worldId = parseU64(next(a.c_str()), ok);
			if (!ok || worldId == 0) {
				std::fprintf(stderr, "ERROR: invalid world ID\n");
				return 2;
			}
		}
		else {
			std::fprintf(stderr, "ERROR: unknown argument: %s\n", a.c_str());
			usage(argv[0]);
			return 2;
		}
	}

	if (!dumpPath.empty()) {
		return dumpWorld(dumpPath);
	}

	if (timestamp == 0) {
		timestamp = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::system_clock::now().time_since_epoch())
						.count();
	}

	return makeWorld(identityPath, moonPath, outputPath, timestamp, worldId);
}
