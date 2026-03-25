#include "kernel.h"

/*
 * exec.c — Program loader and process launch path.
 *
 * Loads a flat binary from the floppy filesystem into PROC_BASE
 * and calls it.  The program returns via near RET.
 */

static struct fs_dirent exec_dirent;

int __cdecl exec_run(const char *name)
{
    int loaded;
    typedef void (__cdecl *proc_entry_t)(void);
    proc_entry_t entry_fn;

    if (fs_find(name, &exec_dirent) != 0) {
        kputs("exec: file not found: ");
        kputs(name);
        kputs("\r\n");
        return -1;
    }

    if (exec_dirent.size > PROC_MAX_SIZE) {
        kputs("exec: program too large\r\n");
        return -1;
    }

    loaded = fs_read_file(&exec_dirent, (u8 *)PROC_BASE, (u16)PROC_MAX_SIZE);
    if (loaded < 0) {
        kputs("exec: load failed\r\n");
        return -1;
    }

    kputs("exec: running '");
    kputs(name);
    kputs("' (");
    print_hex_word((u16)loaded);
    kputs(" bytes)\r\n");

    /* Call the program. It returns via near RET. */
    entry_fn = (proc_entry_t)PROC_BASE;
    entry_fn();

    return 0;
}
