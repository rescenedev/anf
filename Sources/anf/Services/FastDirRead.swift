import Darwin
import Foundation

/// One directory entry from a bulk read — name, type, size and dates, all without
/// a per-item `stat`.
struct FastDirEntry: Sendable {
    let name: String
    let isDir: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
}

/// Native bulk directory listing via `getattrlistbulk(2)`: name, object type,
/// size and timestamps for every entry in a handful of syscalls, with **no
/// per-item `stat`**. This is what lets a 27k-entry folder load near-instantly —
/// Foundation's `contentsOfDirectory(includingPropertiesForKeys:)` does the
/// equivalent of a stat per file, which dominates on huge directories.
enum FastDirRead {
    // Common attribute bits (raw UInt32 to dodge Int32/overflow import quirks).
    private static let RETURNED_ATTRS: attrgroup_t = 0x8000_0000
    private static let NAME: attrgroup_t          = 0x0000_0001
    private static let OBJTYPE: attrgroup_t       = 0x0000_0008
    private static let CRTIME: attrgroup_t        = 0x0000_0200
    private static let MODTIME: attrgroup_t       = 0x0000_0400
    // File attribute group.
    private static let FILE_DATALENGTH: attrgroup_t = 0x0000_0200

    // BSD vnode types (sys/vnode.h): VDIR=2, VLNK=5.
    private static let VTYPE_DIR: fsobj_type_t = 2
    private static let VTYPE_LNK: fsobj_type_t = 5

    /// Returns nil on any failure so the caller can fall back to FileManager.
    static func list(path: String) -> [FastDirEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = RETURNED_ATTRS | NAME | OBJTYPE | CRTIME | MODTIME
        attrList.fileattr = FILE_DATALENGTH

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var entries: [FastDirEntry] = []
        entries.reserveCapacity(4096)

        while true {
            let count = getattrlistbulk(fd, &attrList, buf, bufSize, 0)
            if count < 0 { return entries.isEmpty ? nil : entries }   // error
            if count == 0 { break }                                   // exhausted

            var p = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let entryStart = p
                let length = p.loadUnaligned(as: UInt32.self)
                var field = p.advanced(by: MemoryLayout<UInt32>.size)

                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

                var name = ""
                var objType: fsobj_type_t = 0
                var created = Date.distantPast
                var modified = Date.distantPast
                var size: Int64 = 0

                // Common group, packed in ascending bit order.
                if returned.commonattr & NAME != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = field.advanced(by: Int(ref.attr_dataoffset))
                    name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                    field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                }
                if returned.commonattr & OBJTYPE != 0 {
                    objType = field.loadUnaligned(as: fsobj_type_t.self)
                    field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
                }
                if returned.commonattr & CRTIME != 0 {
                    let ts = field.loadUnaligned(as: timespec.self)
                    created = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                }
                if returned.commonattr & MODTIME != 0 {
                    let ts = field.loadUnaligned(as: timespec.self)
                    modified = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
                    field = field.advanced(by: MemoryLayout<timespec>.size)
                }
                // File group (absent for directories).
                if returned.fileattr & FILE_DATALENGTH != 0 {
                    size = field.loadUnaligned(as: off_t.self)
                    field = field.advanced(by: MemoryLayout<off_t>.size)
                }

                if name != "." && name != ".." && !name.isEmpty {
                    entries.append(FastDirEntry(
                        name: name,
                        isDir: objType == VTYPE_DIR,
                        isSymlink: objType == VTYPE_LNK,
                        isHidden: name.hasPrefix("."),
                        size: size, modified: modified, created: created))
                }
                p = entryStart.advanced(by: Int(length))
            }
        }
        return entries
    }
}
