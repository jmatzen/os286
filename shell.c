typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;

#ifndef __WATCOMC__
#define __cdecl
#endif

#define CMD_BUF_LEN 64
#define DEFAULT_DUMP_LEN 128U
#define MAX_DUMP_LEN 256U

extern void __cdecl serial_putchar(int ch);
extern u8 __cdecl serial_getchar(void);
extern u8 __cdecl pm_read_phys(u16 addr_lo, u16 addr_hi);
extern void __cdecl pm_write_phys(u16 addr_lo, u16 addr_hi, int value);
extern void __cdecl stage2_halt(void);

struct command {
    const char *name;
    void (__cdecl *handler)(const char *args);
};

static char cmd_buf[CMD_BUF_LEN + 1];
static const char *parsed_next;
static u32 parsed_value;

static const char msg_banner[] =
    "\r\n"
    "286 PM Shell  --  C stage2 via Open Watcom\r\n"
    "Type 'help' for commands.\r\n"
    "\r\n";

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

static void putch(char ch)
{
    serial_putchar((unsigned char)ch);
}

static void puts_raw(const char *text)
{
    while (*text != 0) {
        putch(*text);
        ++text;
    }
}

static void print_hex_digit(u8 value)
{
    if (value < 10) {
        putch((char)('0' + value));
    } else {
        putch((char)('a' + (value - 10)));
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
            putch('\r');
            putch('\n');
            return length;
        }

        if (ch == '\b' || ch == 0x7f) {
            if (length != 0) {
                --length;
                putch('\b');
                putch(' ');
                putch('\b');
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
        putch((char)ch);
    }
}

static u8 read_phys_byte(u32 address)
{
    return pm_read_phys((u16)address, (u16)(address >> 16));
}

static void write_phys_byte(u32 address, u8 value)
{
    pm_write_phys((u16)address, (u16)(address >> 16), value);
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

    puts_raw(msg_unknown);
}

static void __cdecl cmd_help(const char *args)
{
    (void)args;
    puts_raw(msg_help);
}

static void __cdecl cmd_peek(const char *args)
{
    u32 address;
    u8 value;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        puts_raw(msg_usage_peek);
        return;
    }
    address = parsed_value;

    value = read_phys_byte(address);

    putch('[');
    print_hex24(address);
    puts_raw("] = ");
    print_hex_byte(value);
    putch('\r');
    putch('\n');
}

static void __cdecl cmd_poke(const char *args)
{
    u32 address;
    u32 value;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        puts_raw(msg_usage_poke);
        return;
    }
    address = parsed_value;
    args = skip_spaces(parsed_next);

    if (!parse_hex_value(args, 2)) {
        puts_raw(msg_usage_poke);
        return;
    }
    value = parsed_value;

    write_phys_byte(address, (u8)value);
    puts_raw(msg_ok);
}

static void __cdecl cmd_dump(const char *args)
{
    u32 address;
    u32 count = DEFAULT_DUMP_LEN;
    u32 row_offset = 0;

    args = skip_spaces(args);
    if (!parse_hex_value(args, 6)) {
        puts_raw(msg_usage_dump);
        return;
    }
    address = parsed_value;
    args = skip_spaces(parsed_next);

    if (*args != 0) {
        if (!parse_hex_value(args, 4)) {
            puts_raw(msg_usage_dump);
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
        puts_raw(": ");

        for (column = 0; column < row_count; ++column) {
            u8 value = read_phys_byte((row_address + column) & 0x00ffffffUL);
            if (column == 8U) {
                putch(' ');
            }
            print_hex_byte(value);
            putch(' ');
        }

        for (; column < 16U; ++column) {
            if (column == 8U) {
                putch(' ');
            }
            puts_raw("   ");
        }

        puts_raw(" |");

        for (column = 0; column < row_count; ++column) {
            u8 value = read_phys_byte((row_address + column) & 0x00ffffffUL);
            if (value < 0x20 || value > 0x7e) {
                value = '.';
            }
            putch((char)value);
        }

        putch('|');
        putch('\r');
        putch('\n');

        row_offset += row_count;
        count -= row_count;
    }
}

static void __cdecl cmd_halt(const char *args)
{
    (void)args;
    puts_raw(msg_halting);
    stage2_halt();
}

void __cdecl kmain(void)
{
    puts_raw(msg_banner);

    for (;;) {
        puts_raw(msg_prompt);
        if (read_line() == 0U) {
            continue;
        }
        dispatch_command(cmd_buf);
    }
}
