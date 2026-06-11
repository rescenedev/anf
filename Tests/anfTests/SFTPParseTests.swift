import Foundation
@testable import anf

func runSFTPParseTests() {
    T.group("SFTPClient.parse") {
        let dir = SFTPClient.parse("drwxr-xr-x   58 ubuntu   ubuntu      12288 Jun 11 06:42 work")
        T.equal(dir?.name, "work", "dir name")
        T.equal(dir?.isDir, true, "is dir")
        T.equal(dir?.isSymlink, false, "dir not symlink")

        let file = SFTPClient.parse("-rw-r--r--    1 ubuntu   ubuntu        4804 Nov 13  2023 .bashrc")
        T.equal(file?.name, ".bashrc", "file name")
        T.equal(file?.isDir, false, "is file")
        T.equal(file?.size, 4804, "file size")

        let spaced = SFTPClient.parse("-rw-r--r--    1 u g  10 Jun  3 04:54 (금융위원회) 규정 v2.hwpx")
        T.equal(spaced?.name, "(금융위원회) 규정 v2.hwpx", "name with spaces/parens/korean")

        let link = SFTPClient.parse("lrwxrwxrwx    1 u g  7 Jun  3 04:54 link -> /etc/target")
        T.equal(link?.name, "link", "symlink name strips target")
        T.equal(link?.isSymlink, true, "is symlink")

        T.notNil(SFTPClient.parse("-rw-r--r-- 1 u g 1 Jun 11 06:42 a")?.modified, "time date parses")
        T.notNil(SFTPClient.parse("-rw-r--r-- 1 u g 1 Oct  4  2020 b")?.modified, "year date parses")

        T.isNil(SFTPClient.parse("sftp> ls -la"), "prompt line rejected")
        T.isNil(SFTPClient.parse(""), "empty rejected")
        T.isNil(SFTPClient.parse("Connected to host."), "banner rejected")
    }
}
