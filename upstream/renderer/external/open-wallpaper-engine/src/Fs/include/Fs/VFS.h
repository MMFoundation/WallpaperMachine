#pragma once
#include <vector>
#include <memory>
#include <string>
#include <tuple>
#include <algorithm>
#include "Fs.h"
#include "Utils/Logging.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace  fs
{

class VFS : NoCopy,NoMove {
public:
	struct MountedFs {
		std::string name;
		std::string mountPoint;
		std::unique_ptr<Fs> fs;
		static bool CheckMountPoint(const std::string_view mountPoint) {
			return ! mountPoint.empty() && mountPoint.front() == '/' && mountPoint.back() != '/';
		}
		static bool InMountPoint(const std::string_view mountPoint, const std::string_view path) {
			// CLEANROOM UV7
			(void)mountPoint;
			(void)path;
			return false;
		}
		static std::string GetPathInMount(const std::string_view mountPoint, const std::string_view path) {
			// CLEANROOM UV8
			(void)mountPoint;
			(void)path;
			return {};
		}
	};
public:
	VFS() = default;
	~VFS() = default;

	bool Mount(std::string_view mountpoint, std::unique_ptr<Fs> fs, std::string_view name="") {
		// CLEANROOM UV9
		(void)mountpoint;
		(void)fs;
		(void)name;
		return false;
	}
	bool Unmount(std::string_view mountpoint) {
		// CLEANROOM UV10
		(void)mountpoint;
		return false;
	}
	bool IsMounted(std::string_view name) {
		// CLEANROOM UV11
		(void)name;
		return false;
	}
	std::shared_ptr<IBinaryStream> Open(std::string_view path) {
		// CLEANROOM UV12
		(void)path;
		return nullptr;
	}
	std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) {
		// CLEANROOM UV13
		(void)path;
		return nullptr;
	}
	/// Publishes `from` as `to`, both of which must resolve to the same mount.
	///
	/// Refuses rather than approximating when they do not: moving a file across
	/// two file systems is a copy, and a copy is exactly what the callers of
	/// this are avoiding.
	bool Rename(std::string_view from, std::string_view to) {
		auto owner = std::find_if(m_mountedFss.rbegin(), m_mountedFss.rend(), [&to](const auto& mfs) {
			return MountedFs::InMountPoint(mfs.mountPoint, to);
		});
		if (owner == std::rend(m_mountedFss)) return false;
		if (! MountedFs::InMountPoint(owner->mountPoint, from)) return false;
		return owner->fs->Rename(MountedFs::GetPathInMount(owner->mountPoint, from),
		                         MountedFs::GetPathInMount(owner->mountPoint, to));
	}
	bool Contains(std::string_view path) const {
		// CLEANROOM UV14
		(void)path;
		return false;
	}
private:
	std::vector<MountedFs> m_mountedFss;
};

inline std::string GetFileContent(fs::VFS& vfs, std::string_view path) {
	// CLEANROOM UV15
	(void)vfs;
	(void)path;
	return {};
}

}
}
