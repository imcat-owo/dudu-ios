//
//  ThemeOffload.m
//  MinisApp
//
//  Native offload handler for `minis-theme`.
//  Subcommands: get, apply, export, reset
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Dudu-Swift.h")
#import "Dudu-Swift.h"
#else
@interface ThemeOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)currentPack;
+ (NSDictionary * _Nonnull)applyJSON:(NSString * _Nonnull)json;
+ (NSDictionary * _Nonnull)exportJSONWithIncludeWallpaper:(BOOL)includeWallpaper;
+ (NSDictionary * _Nonnull)resetPack;
+ (NSDictionary * _Nonnull)saveCurrentWithName:(NSString * _Nonnull)name;
+ (NSDictionary * _Nonnull)listSaved;
+ (NSDictionary * _Nonnull)applySavedWithId:(NSString * _Nonnull)id;
+ (NSDictionary * _Nonnull)deleteSavedWithId:(NSString * _Nonnull)id;
+ (NSDictionary * _Nonnull)renameSavedWithId:(NSString * _Nonnull)id name:(NSString * _Nonnull)name;
@end
#endif

static NSString *const TOOL_NAME = @"minis-theme";

static NSString *const HELP_TEXT =
    @"minis-theme - Apply and export 我的小家 AI theme packs\n"
     "\n"
     "USAGE:\n"
     "  minis-theme <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  get       Show the current theme pack (no wallpaper bytes)\n"
     "  apply     Apply a theme pack from --file or stdin JSON\n"
     "  export    Dump the current pack as JSON\n"
     "  reset     Restore the default warm-paper pack\n"
     "  save      Save the current pack into the theme library\n"
     "  list      List saved themes\n"
     "  use       Apply a saved theme by --id\n"
     "  rename    Rename a saved theme --id --name\n"
     "  delete    Delete a saved theme by --id\n"
     "\n"
     "OPTIONS:\n"
     "  --file <path>         JSON theme pack (guest path)\n"
     "  --wallpaper           export: include wallpaper JPEG as base64\n"
     "  --name <text>         save/rename display name\n"
     "  --id <uuid>           saved theme id\n"
     "  --help, -h            Show this help\n"
     "  --compact             Minimize JSON output\n"
     "  -q, --quiet           Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  minis-theme get\n"
     "  minis-theme apply --file /var/minis/workspace/theme.json\n"
     "  minis-theme save --name 奶霜莓粉\n"
     "  minis-theme list\n"
     "  minis-theme use --id <uuid>\n"
     "  minis-theme reset\n"
     "\n"
     "THEME PACK:\n"
     "  colorsLight.accent drives thinking title, tool capsules, slash thinking.\n"
     "  Do not hardcode blue/green. Pink theme stays pink.\n"
     "  Skill `minis-theme` documents the JSON. This is an app skin, not a PPT.\n";

static NSDictionary *strip_ok(NSDictionary *raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return raw;
    NSMutableDictionary *copy = [raw mutableCopy];
    [copy removeObjectForKey:@"ok"];
    return copy;
}

static int emit_bridge(NSDictionary *raw, NSString *action,
                       int stdout_fd, BOOL compact, BOOL quiet) {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, action, NOFF_ERR_INTERNAL_ERROR,
                                            @"theme bridge returned nothing");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id okVal = raw[@"ok"];
    BOOL ok = YES;
    if ([okVal isKindOfClass:[NSNumber class]]) ok = [okVal boolValue];
    if (!ok) {
        NSString *code = raw[@"error"] ?: NOFF_ERR_INVALID_ARGS;
        NSString *msg = raw[@"message"] ?: @"theme command failed";
        NSDictionary *err = noff_json_error(TOOL_NAME, action, code, msg);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *result = noff_json_envelope(TOOL_NAME, action, strip_ok(raw));
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_get(int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *raw = [ThemeOffloadBridge currentPack];
    return emit_bridge(raw, @"get", stdout_fd, compact, quiet);
}

static int cmd_apply(int argc, char **argv, int stdin_fd, int stdout_fd,
                     int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *filePath = noff_find_arg(argc, argv, "--file");
    NSString *json = nil;
    if (filePath.length > 0) {
        NSString *host = noff_resolve_host_path(filePath);
        if (!host) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"apply", NOFF_ERR_NO_DATA,
                                                [NSString stringWithFormat:@"Cannot resolve %@", filePath]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSError *readErr = nil;
        NSString *text = [NSString stringWithContentsOfFile:host encoding:NSUTF8StringEncoding error:&readErr];
        if (!text) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"apply", NOFF_ERR_NO_DATA,
                                                readErr.localizedDescription ?: @"unreadable file");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        json = text;
    } else {
        json = noff_read_stdin(stdin_fd);
    }
    if (json.length == 0) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"apply", NOFF_ERR_INVALID_ARGS,
                                            @"Need --file <path> or JSON on stdin.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *raw = [ThemeOffloadBridge applyJSON:json];
    return emit_bridge(raw, @"apply", stdout_fd, compact, quiet);
}

static int cmd_export(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    BOOL wallpaper = noff_has_flag(argc, argv, "--wallpaper");
    NSDictionary *raw = [ThemeOffloadBridge exportJSONWithIncludeWallpaper:wallpaper];
    return emit_bridge(raw, @"export", stdout_fd, compact, quiet);
}

static int cmd_reset(int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *raw = [ThemeOffloadBridge resetPack];
    return emit_bridge(raw, @"reset", stdout_fd, compact, quiet);
}

static int cmd_save(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *name = noff_find_arg(argc, argv, "--name") ?: @"";
    NSDictionary *raw = [ThemeOffloadBridge saveCurrentWithName:name];
    return emit_bridge(raw, @"save", stdout_fd, compact, quiet);
}

static int cmd_list(int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *raw = [ThemeOffloadBridge listSaved];
    return emit_bridge(raw, @"list", stdout_fd, compact, quiet);
}

static int cmd_use(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *sid = noff_find_arg(argc, argv, "--id");
    if (sid.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"use", NOFF_ERR_INVALID_ARGS, @"Need --id");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *raw = [ThemeOffloadBridge applySavedWithId:sid];
    return emit_bridge(raw, @"use", stdout_fd, compact, quiet);
}

static int cmd_delete(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *sid = noff_find_arg(argc, argv, "--id");
    if (sid.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete", NOFF_ERR_INVALID_ARGS, @"Need --id");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *raw = [ThemeOffloadBridge deleteSavedWithId:sid];
    return emit_bridge(raw, @"delete", stdout_fd, compact, quiet);
}

static int cmd_rename(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *sid = noff_find_arg(argc, argv, "--id");
    NSString *name = noff_find_arg(argc, argv, "--name");
    if (sid.length == 0 || name.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"rename", NOFF_ERR_INVALID_ARGS, @"Need --id and --name");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *raw = [ThemeOffloadBridge renameSavedWithId:sid name:name];
    return emit_bridge(raw, @"rename", stdout_fd, compact, quiet);
}

static int theme_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }
    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");
    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) subcmd = @"get";

    if ([subcmd isEqualToString:@"get"]) {
        return cmd_get(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"apply"]) {
        return cmd_apply(argc, argv, stdin_fd, stdout_fd, stderr_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"export"]) {
        return cmd_export(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"reset"]) {
        return cmd_reset(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"save"]) {
        return cmd_save(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"list"]) {
        return cmd_list(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"use"]) {
        return cmd_use(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"delete"]) {
        return cmd_delete(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"rename"]) {
        return cmd_rename(argc, argv, stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:
                                          @"Unknown command '%@'. Valid: get, apply, export, reset, save, list, use, rename, delete.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void theme_offload_register(void) {
    int err = native_offload_add_handler("minis-theme", theme_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-theme");
        NSLog(@"NativeOffloads: minis-theme handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register minis-theme handler (err=%d)", err);
    }
}
