// SPDX-License-Identifier: GPL-2.0-or-later
#include "targz.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static int mkdirs(const char* path) {
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (char* p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    return mkdir(tmp, 0755);
}

static long octal(const char* s, size_t n) {
    long v = 0;
    while (n > 0 && (*s == ' ' || *s == '\0')) { s++; n--; }
    while (n > 0 && *s >= '0' && *s <= '7') { v = v * 8 + (*s - '0'); s++; n--; }
    return v;
}

int targz_extract(const char* tarGzPath, const char* destDir) {
    FILE* f = fopen(tarGzPath, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long gzLen = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (gzLen <= 0) { fclose(f); errno = EINVAL; return -1; }
    unsigned char* gz = malloc((size_t)gzLen);
    if (!gz) { fclose(f); errno = ENOMEM; return -1; }
    if (fread(gz, 1, (size_t)gzLen, f) != (size_t)gzLen) {
        free(gz); fclose(f); errno = EIO; return -1;
    }
    fclose(f);

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // 47 = auto-detect gzip/zlib wrapping.
    if (inflateInit2(&strm, 47) != Z_OK) { free(gz); errno = EINVAL; return -1; }
    size_t cap = 64 * 1024 * 1024;
    unsigned char* tar = malloc(cap);
    if (!tar) { inflateEnd(&strm); free(gz); errno = ENOMEM; return -1; }
    strm.next_in = gz;
    strm.avail_in = (uInt)gzLen;
    size_t tarLen = 0;
    int ret;
    do {
        if (tarLen == cap) {
            cap *= 2;
            unsigned char* ntar = realloc(tar, cap);
            if (!ntar) { free(tar); inflateEnd(&strm); free(gz); errno = ENOMEM; return -1; }
            tar = ntar;
        }
        strm.next_out = tar + tarLen;
        strm.avail_out = (uInt)(cap - tarLen);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
            free(tar); inflateEnd(&strm); free(gz); errno = EIO; return -1;
        }
        tarLen = cap - strm.avail_out;
    } while (ret != Z_STREAM_END);
    inflateEnd(&strm);
    free(gz);

    // Walk 512-byte ustar records.
    char longName[1024] = {0};
    size_t off = 0;
    while (off + 512 <= tarLen) {
        unsigned char* h = tar + off;
        if (h[0] == '\0') break; // end of archive (two zero blocks)
        char name[101];
        memcpy(name, h, 100);
        name[100] = '\0';
        long size = octal((const char*)h + 124, 12);
        char type = (char)h[156];
        // PAX extended header: find "path=" for the next file.
        if (type == 'x' || type == 'g') {
            size_t pos = 0;
            while (pos + 30 < (size_t)size) {
                // record: "<len> <key>=<value>\n"
                char* rec = (char*)tar + off + 512 + pos;
                char* sp = memchr(rec, ' ', 30);
                if (!sp) break;
                char* eq = memchr(sp + 1, '=', (size_t)size - pos - (size_t)(sp - rec));
                if (!eq) break;
                if (strncmp(sp + 1, "path=", 5) == 0) {
                    size_t vlen = (size_t)size - pos - (size_t)(eq - rec) - 1;
                    if (vlen >= sizeof(longName)) vlen = sizeof(longName) - 1;
                    memcpy(longName, eq + 1, vlen);
                    longName[vlen] = '\0';
                    // strip trailing newline
                    char* nl = strchr(longName, '\n');
                    if (nl) *nl = '\0';
                }
                long rlen = strtol(rec, NULL, 10);
                if (rlen <= 0) break;
                pos += (size_t)rlen;
            }
            off += 512 + (size_t)((size + 511) & ~511L);
            continue;
        }
        const char* useName = longName[0] ? longName : name;
        if (type == 'L') {
            // GNU long name: data block holds the name.
            size_t nlen = (size_t)size;
            if (nlen >= sizeof(longName)) nlen = sizeof(longName) - 1;
            memcpy(longName, tar + off + 512, nlen);
            longName[nlen] = '\0';
            off += 512 + (size_t)((size + 511) & ~511L);
            continue;
        }
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s/%s", destDir, useName);
        if (type == '5') {
            mkdirs(full);
        } else if (type == '0' || type == '\0') {
            char* slash = strrchr(full, '/');
            if (slash) {
                *slash = '\0';
                mkdirs(full);
                *slash = '/';
            }
            int fd = open(full, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) { free(tar); errno = EIO; return -1; }
            size_t written = 0;
            while (written < (size_t)size) {
                ssize_t w = write(fd, tar + off + 512 + written, (size_t)size - written);
                if (w <= 0) { close(fd); free(tar); errno = EIO; return -1; }
                written += (size_t)w;
            }
            close(fd);
        }
        longName[0] = '\0';
        off += 512 + (size_t)((size + 511) & ~511L);
    }
    free(tar);
    return 0;
}
