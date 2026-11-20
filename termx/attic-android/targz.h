// targz: extract a .tar.gz into a directory. Only what staging the
// LineageOS release needs: regular files, directories, GNU long names,
// PAX path records. Returns 0 on success, -1 on failure (errno set).
// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KTERM_TARGZ_H
#define KTERM_TARGZ_H

#include <stddef.h>

int targz_extract(const char* tarGzPath, const char* destDir);

#endif
