#include "kernel.h"

#define CMD_BUF_LEN 64
#define DEFAULT_DUMP_LEN 128U
#define MAX_DUMP_LEN 256U

extern u8 __cdecl serial_getchar(void);

struct command {
    const char *name;
    void (__cdecl *handler)(const char *args);
};

static char cmd_buf[CMD_BUF_LEN + 1];
static const char *parsed_next;
static u32 parsed_value;

static const char msg_prompt[] = "> ";
static const char msg_unknown[] = "unknown command (try 'help')\r\n";
static const char msg_ok[] = "ok\r\n";
static const char msg_halting[] = "Halting.\r\n";
static const char msg_usage_peek[] = "usage: peek <hex-addr>             (addr up to 6 hex digits)\r\n";
static const char msg_usage_poke[] = "usage: poke <hex-addr> <hex-val>   (addr up to 6 hex digits)\r\n";
static const char msg_usage_dump[] = "usage: dump <hex-addr> [<hex-len>] (addr up to 6 hex digits)\r\n";
static const char msg_help[] =
    "Commands:\r\n"
    "  help              this list\r\n"
    "  peek <addr>       read byte at physical address (24-bit, up to 6 hex digits)\r\n"
    "  poke <addr> <val> write byte to physical address (24-bit)\r\n"
    "  dump <addr> [len] hex+ASCII dump (default 128 bytes; addr 24-bit)\r\n"
    "  halt              halt the CPU\r\n";

static void __cdecl cmd_help(const char *args);
static void __cdecl cmd_peek(const char *args);
static void __cdecl cmd_poke(const char *args);
static void __cdecl cmd_dump(const char *args);
static void __cdecl cmd_halt(const char *args);

static const struct command commands[] = {
    { "help", cmd_help },
    { "peek", cmd_peek },
    { "poke", cmd_poke },
    { "dump", cmd_dump },
    { "halt", cmd_halt },
    { 0, 0 }
};

static void print_hex_digit(u8 value)
{
    if (value < 10) {
        kputch((char)('0' + value));
    } else {
        kputch((char)('a' + (value - 10)));
    }
}

static void print_hex_byte(u8 value)
{
    print_hex_digit((u8)(value >> 4));
    print_hex_digit((u8)(value & 0x0f));
}

static void print_hex_word(u16 value)
{
    print_hex_byte((u8)(value >> 8));
    print_hex_byte((u8)(value & 0xff));
}

static void print_hex24(u32 value)
{
    value &= 0x00ffffffUL;
    print_hex_byte((u8)(value >> 16));
    print_hex_word((u16)value);
}

static char lower_char(char ch)
{
    if (ch >= 'A' && ch <= 'Z') {
        return (char)(ch | 0x20);
    }
    return ch;
}

static int hex_value(char ch)
{
    ch = lower_char(ch);
    if (ch >= '0' && ch <= '9') {
        return ch - '0';
    }
    if (ch >= 'a' && ch <= 'f') {
        return ch - 'a' + 10;
    }
    return -1;
}

static const char *skip_spaces(const char *text)
{
    while (*text == ' ') {
        ++text;
    }
    return text;
}

static int parse_hex_value(const char *text, unsigned max_digits)
{
    u32 parsed = 0;
    unsigned digits = 0;

    while (digits < max_digits) {
        int nibble = hex_value(*text);
        if (nibble < 0) {
            break;
        }
        parsed = (parsed << 4) | (u32)nibble;
        ++text;
        ++digits;
    }

    if (digits == 0) {
        return 0;
    }

    parsed_next = text;
    parsed_value = parsed;
    return 1;
}

static int match_command(const char *input, const char *command)
{
    while (*command != 0) {
        if (lower_char(*input) != lower_char(*command)) {
            return 0;
        }
        ++input;
        ++command;
    }

    return *input == 0 || *input == ' ';
}

static unsigned read_line(void)
{
    unsigned length = 0;

    for (;;) {
        u8 ch = serial_getchar();

        if (ch == '\r') {
            cmd_buf[length] = 0;
            kputch('\r');
            kputch('\n');
            return length;
        }

        if (ch == '\b' || ch == 0x7f) {
            if (length != 0) {
                --length;
                kputch('\b');
                kputch(' ');
                kputch('\b');
            }
            continue;
        }

        if (ch < ' ') {
            continue;
        }

        if (length >= CMD_BUF_LEN) {
            continue;
        }

        cmd_buf[length] = (char)ch;
        ++length;
        kputch((char)ch);
    }
}

static void dispatch_command(const char *input)
{
    const struct command *command;

    input = skip_spaces(input);
    if (*input == 0) {
        return;
    }

    for (command = commands; command->name != 0; ++command) {
        if (match_command(input, command->name)) {
            while (*input != 0 && *input != ' ') {
                ++input;
            }
            command->handler(skip_spaces(input));
            return;
        }
    }

    kputs(msg_unknown);
}

static void __cdecl cmd_help(const char *args)
{
    (void)args;
    kputs(msg_help);
}

static void __cdecl cmd_peek(const char *args)
{
    u32 address;
    u8 value;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        kputs(msg_usage_peek);
        return;
    }
    address = parsed_value;

    value = kread_phys_byte(address);

    kputch('[');
    print_hex24(address);
    kputs("] = ");
    print_hex_byte(value);
    kputch('\r');
    kputch('\n');
}

static void __cdecl cmd_poke(const char *args)
{
    u32 address;
    u32 value;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        kputs(msg_usage_poke);
        return;
    }
    address = parsed_value;
    args = skip_spaces(parsed_next);

    if (!parse_hex_value(args, 2)) {
        kputs(msg_usage_poke);
        return;
    }
    value = parsed_value;

    kwrite_phys_byte(address, (u8)value);
    kputs(msg_ok);
}

static void __cdecl cmd_dump(const char *args)
{
    u32 address;
    u32 count = DEFAULT_DUMP_LEN;
    u32 row_offset = 0;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        kputs(msg_usage_dump);
        return;
    }
    address = parsed_value;
    args = skip_spaces(parsed_next);

    if (*args != 0) {
        if (!parse_hex_value(args, 4)) {
            kputs(msg_usage_dump);
            return;
        }
        count = parsed_value;
        if (count > MAX_DUMP_LEN) {
            count = MAX_DUMP_LEN;
        }
    }

    while (count != 0) {
        u32 row_address = (address + row_offset) & 0x00ffffffUL;
        unsigned row_count = (count > 16U) ? 16U : (unsigned)count;
        unsigned column;

        print_hex24(row_address);
        kputs(": ");

        for (column = 0; column < row_count; ++column) {
            u8 value = kread_phys_byte((row_address + column) & 0x00ffffffUL);
            if (column == 8U) {
                kputch(' ');
            }
            print_hex_byte(value);
            kputch(' ');
        }

        for (; column < 16U; ++column) {
            if (column == 8U) {
                kputch(' ');
            }
            kputs("   ");
        }

        kputs(" |");

        for (column = 0; column < row_count; ++column) {
            u8 value = kread_phys_byte((row_address + column) & 0x00ffffffUL);
            if (value < 0x20 || value > 0x7e) {
                value = '.';
            }
            kputch((char)value);
        }

        kputch('|');
        kputch('\r');
        kputch('\n');

        row_offset += row_count;
        count -= row_count;
    }
}

static void __cdecl cmd_halt(const char *args)
{
    (void)args;
    kputs(msg_halting);
    khalt();
}

void __cdecl console_run(void)
{
    for (;;) {
        kputs(msg_prompt);
        if (read_line() == 0U) {
            continue;
        }
        dispatch_command(cmd_buf);
    }
}
