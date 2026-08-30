const std = @import("std");
const input_action = @import("../../core/input/input_action.zig");

const InputEscapeAction = input_action.Action;
const MousePointerKind = input_action.MousePointerKind;

pub const MouseInput = struct {
    button: u16 = 0,
    column: u16 = 0,
    row: u16 = 0,
    sgr_bytes: u8 = 0,
    discard_remaining: u8 = 0,
    // Scratch fields for win32-input-mode reports. Mouse stages and win32
    // stages never run concurrently, so one accumulator is shared; `reset`
    // clears them at every stage boundary like the mouse fields.
    win32_vk: u16 = 0,
    win32_scan: u16 = 0,
    win32_char: u16 = 0,
    win32_key_down: u16 = 0,
    win32_state: u16 = 0,
    win32_field: u8 = win32_scan_field,

    pub fn reset(self: *MouseInput) void {
        self.* = .{};
    }
};

fn appendCsiDigitSaturating(param: *u16, byte: u8) void {
    const digit: u16 = byte - '0';
    const multiplied = std.math.mul(u16, param.*, 10) catch std.math.maxInt(u16);
    param.* = std.math.add(u16, multiplied, digit) catch std.math.maxInt(u16);
}

const escape_meta_mask: u8 = 0x80;
const sgr_mouse_stage: u8 = 7;
const sgr_mouse_column_stage: u8 = 8;
const sgr_mouse_row_stage: u8 = 9;
const legacy_x10_button_stage: u8 = 10;
const legacy_x10_column_stage: u8 = 11;
const legacy_x10_row_stage: u8 = 12;
const discarded_sgr_mouse_stage: u8 = 13;
const discarded_x10_mouse_stage: u8 = 14;
const control_sequence_discard_stage: u8 = 15;
const kitty_escape_event_type_stage: u8 = 16;
const sgr_mouse_max_bytes: u8 = 18;
const control_sequence_discard_max_bytes: u16 = 32;
const kitty_up_key: u16 = 57352;
const kitty_down_key: u16 = 57353;
const shift_modifier: u16 = 0x01;
const alt_modifier: u16 = 0x02;
const ctrl_modifier: u16 = 0x04;
const super_modifier: u16 = 0x08;

// win32-input-mode (`CSI ?9001 h`) reports `ESC[VK;Scan;Char;KeyDown;State;Repeat_`.
// The first parameter accumulates through the ordinary CSI param stages, then
// the `_` terminator switches to the dedicated win32 field stages below.
const win32_input_field_stage: u8 = 17;
const win32_vk_field: u8 = 0;
const win32_scan_field: u8 = 1;
const win32_char_field: u8 = 2;
const win32_key_down_field: u8 = 3;
const win32_state_field: u8 = 4;
const win32_repeat_field: u8 = 5;
const win32_shift_state: u16 = 0x0010;
const win32_ctrl_state_mask: u16 = 0x000c; // LEFT | RIGHT
const win32_alt_state_mask: u16 = 0x0003; // LEFT | RIGHT

fn composerMove(kind: input_action.MoveKind, modifiers: u16) InputEscapeAction {
    return .{ .composer_shortcut = .{ .move = .{
        .kind = kind,
        .extend_selection = (modifiers & shift_modifier) != 0,
    } } };
}

fn modifiedArrowAction(byte: u8, modifiers: u16, meta_prefixed: bool) ?InputEscapeAction {
    if ((modifiers & super_modifier) != 0) return switch (byte) {
        'A' => composerMove(.draft_start, modifiers),
        'B' => composerMove(.draft_end, modifiers),
        'C' => composerMove(.line_end, modifiers),
        'D' => composerMove(.line_start, modifiers),
        'H' => composerMove(.draft_start, modifiers),
        'F' => composerMove(.draft_end, modifiers),
        else => null,
    };
    if (meta_prefixed or (modifiers & alt_modifier) != 0) return switch (byte) {
        'A' => composerMove(.paragraph_up, modifiers),
        'B' => composerMove(.paragraph_down, modifiers),
        'C' => composerMove(.word_right, modifiers),
        'D' => composerMove(.word_left, modifiers),
        else => null,
    };
    if ((modifiers & ctrl_modifier) != 0) return switch (byte) {
        'C' => composerMove(.word_right, modifiers),
        'D' => composerMove(.word_left, modifiers),
        'A' => composerMove(.visual_up, modifiers),
        'B' => composerMove(.visual_down, modifiers),
        'H' => composerMove(.draft_start, modifiers),
        'F' => composerMove(.draft_end, modifiers),
        else => null,
    };
    if ((modifiers & shift_modifier) != 0) return switch (byte) {
        'A' => composerMove(.visual_up, modifiers),
        'B' => composerMove(.visual_down, modifiers),
        'C' => composerMove(.character_right, modifiers),
        'D' => composerMove(.character_left, modifiers),
        'H' => composerMove(.line_start, modifiers),
        'F' => composerMove(.line_end, modifiers),
        else => null,
    };
    return null;
}

fn ctrlOKeyAction(meta_prefixed: bool, modifiers: u16) InputEscapeAction {
    if (!meta_prefixed and modifiers == 0x04) return .toggle_full_transcript;
    return .ignore;
}

// Resolve a Kitty CSI u report (`ESC[<keycode>;<mod>u`). Shared by the
// single-parameter and modifier stages, and never returns null so the leading
// ESC's pending-cancel is always cleared.
fn kittyUnicodeKeyAction(keycode: u16, modifiers: u16, meta_prefixed: bool) InputEscapeAction {
    // Strip Caps Lock (bit 6) and Num Lock (bit 7) — lock states, not modifiers.
    const mods = modifiers & 0x3F;
    if (keycode == 27 and mods == 0) return .escape;
    if (keycode == kitty_up_key or keycode == kitty_down_key) {
        if (meta_prefixed or mods != 0) {
            return modifiedArrowAction(
                if (keycode == kitty_up_key) 'A' else 'B',
                mods,
                meta_prefixed,
            ) orelse .ignore;
        }
        return if (keycode == kitty_up_key) .cursor_up else .cursor_down;
    }
    if (keycode == 13 and mods == ctrl_modifier and !meta_prefixed) return .steer_submit;
    if (keycode == 13 and (mods & (shift_modifier | alt_modifier)) != 0) {
        return .insert_newline;
    }
    if (keycode == ' ' and mods == shift_modifier and !meta_prefixed) return .{ .remapped_byte = ' ' };
    if ((keycode == 'a' or keycode == 'A') and (mods & super_modifier) != 0) {
        return .{ .composer_shortcut = .select_all };
    }
    if ((keycode == 'c' or keycode == 'C') and (mods & super_modifier) != 0) {
        return .{ .composer_shortcut = .copy_selection };
    }
    if ((keycode == 'x' or keycode == 'X') and (mods & super_modifier) != 0) {
        return .{ .composer_shortcut = .cut_selection };
    }
    if ((keycode == 'z' or keycode == 'Z') and (mods & super_modifier) != 0) {
        return .{ .composer_shortcut = if ((mods & shift_modifier) != 0) .redo else .undo };
    }
    if ((mods & (shift_modifier | ctrl_modifier)) ==
        (shift_modifier | ctrl_modifier))
    {
        if (keycode == 'a' or keycode == 'A') return composerMove(.line_start, mods);
        if (keycode == 'b' or keycode == 'B') return composerMove(.character_left, mods);
        if (keycode == 'e' or keycode == 'E') return composerMove(.line_end, mods);
        if (keycode == 'f' or keycode == 'F') return composerMove(.character_right, mods);
    }
    if (keycode == 'b' and (mods & alt_modifier) != 0) {
        if ((mods & shift_modifier) != 0) return composerMove(.word_left, mods);
        return .word_left;
    }
    if (keycode == 'f' and (mods & alt_modifier) != 0) {
        if ((mods & shift_modifier) != 0) return composerMove(.word_right, mods);
        return .word_right;
    }
    if ((keycode == 'd' or keycode == 'D') and (meta_prefixed or (mods & 0x02) != 0)) return .delete_word_right;
    if (keycode == 'o' or keycode == 'O') return ctrlOKeyAction(meta_prefixed, mods);
    if ((keycode == 'r' or keycode == 'R') and (mods & 0x08) != 0) return .open_all_sessions;
    if (keycode == 9 and (mods & 0x01) != 0) return .toggle_permission_mode;
    if ((mods & 0x04) != 0) {
        if (keycode == '_') return .{ .remapped_byte = 31 };
        if (keycode >= 'a' and keycode <= 'z') return .{ .remapped_byte = @intCast(keycode - 96) };
        if (keycode >= 'A' and keycode <= 'Z') return .{ .remapped_byte = @intCast(keycode - 64) };
    }
    if (keycode == 127 and (mods & 0x08) != 0) return .delete_to_line_start;
    if (keycode == 127 and (mods & 0x02) != 0) return .delete_word_left;
    if (keycode == 13) return .{ .remapped_byte = '\r' };
    if (keycode == 9) return .{ .remapped_byte = '\t' };
    if (keycode == 127) return .{ .remapped_byte = 127 };
    return .ignore;
}

pub fn controlByteFeatureAction(byte: u8) ?InputEscapeAction {
    return switch (byte) {
        15 => .toggle_full_transcript,
        else => null,
    };
}

// Store one completed win32-input-mode field before the next `;` or the final
// `_`. Field order: VK;Scan;Char;KeyDown;State;Repeat. The repeat count is
// parsed but unused; every report is one action.
fn storeWin32Field(mouse: *MouseInput, value: u16) void {
    switch (mouse.win32_field) {
        win32_scan_field => mouse.win32_scan = value,
        win32_char_field => mouse.win32_char = value,
        win32_key_down_field => mouse.win32_key_down = value,
        win32_state_field => mouse.win32_state = value,
        else => {},
    }
    if (mouse.win32_field < win32_repeat_field) mouse.win32_field += 1;
}

fn win32KittyKeycode(vk: u16, char: u16) u16 {
    if (char >= 0x20 and char < 0x7f) return char;
    if (vk >= 'A' and vk <= 'Z') return vk + 32;
    return vk;
}

// Translate one win32-input-mode key event into the same action space as
// Kitty CSI u reports so Windows input keeps fx's exact key semantics.
fn win32InputKeyAction(vk: u16, char: u16, key_down: u16, state: u16) InputEscapeAction {
    // Release events must not trigger actions, mirroring the kitty rule that
    // only press and repeat are actionable.
    if (key_down == 0) return .ignore;

    const shift = (state & win32_shift_state) != 0;
    const ctrl = (state & win32_ctrl_state_mask) != 0;
    const alt = (state & win32_alt_state_mask) != 0;

    if (alt and !ctrl) {
        return kittyUnicodeKeyAction(win32KittyKeycode(vk, char), alt_modifier, false);
    }
    if (ctrl) {
        if (vk == 13) return .steer_submit;
        if (vk >= 'A' and vk <= 'Z') return .{ .remapped_byte = @intCast(vk - 64) };
        if (vk == 37) return composerMove(.word_left, ctrl_modifier);
        if (vk == 39) return composerMove(.word_right, ctrl_modifier);
        if (vk == 36) return composerMove(.draft_start, ctrl_modifier);
        if (vk == 35) return composerMove(.draft_end, ctrl_modifier);
        return .ignore;
    }

    if (vk == 13) return if (shift) .insert_newline else .{ .remapped_byte = '\r' };
    if (vk == 9) return if (shift) .toggle_permission_mode else .{ .remapped_byte = '\t' };
    if (vk == 8) return .{ .remapped_byte = 127 };
    if (vk == 27) return .escape;
    if (vk == 46) return .delete_next;
    if (vk == 33) return .page_up;
    if (vk == 34) return .page_down;
    if (vk == 36) return .home;
    if (vk == 35) return .end;
    switch (vk) {
        38 => return if (shift)
            modifiedArrowAction('A', shift_modifier, false) orelse .cursor_up
        else
            .cursor_up,
        40 => return if (shift)
            modifiedArrowAction('B', shift_modifier, false) orelse .cursor_down
        else
            .cursor_down,
        37 => return if (shift)
            modifiedArrowAction('D', shift_modifier, false) orelse .cursor_left
        else
            .cursor_left,
        39 => return if (shift)
            modifiedArrowAction('C', shift_modifier, false) orelse .cursor_right
        else
            .cursor_right,
        else => {},
    }
    if (char >= 0x20 and char < 0x7f) return .{ .remapped_byte = @intCast(char) };
    if (vk >= 'A' and vk <= 'Z') return .{ .remapped_byte = @intCast(vk + 32) };
    return .ignore;
}

pub const MouseReportDiscardResult = enum {
    pending,
    report_end,
    bound,
    restart,
};

fn baseEscapeStage(stage: u8) u8 {
    return stage & ~escape_meta_mask;
}

fn hasMetaPrefix(stage: u8) bool {
    return (stage & escape_meta_mask) != 0;
}

fn setBaseEscapeStage(stage: *u8, base: u8) void {
    stage.* = (stage.* & escape_meta_mask) | base;
}

pub fn isLegacyX10PayloadStage(stage: u8) bool {
    return switch (baseEscapeStage(stage)) {
        legacy_x10_button_stage,
        legacy_x10_column_stage,
        legacy_x10_row_stage,
        => true,
        else => false,
    };
}

pub fn isMouseReportPayloadStage(stage: u8) bool {
    return switch (baseEscapeStage(stage)) {
        sgr_mouse_stage,
        sgr_mouse_column_stage,
        sgr_mouse_row_stage,
        legacy_x10_button_stage,
        legacy_x10_column_stage,
        legacy_x10_row_stage,
        => true,
        else => false,
    };
}

pub fn isMouseReportDiscardStage(stage: u8) bool {
    return switch (baseEscapeStage(stage)) {
        discarded_sgr_mouse_stage,
        discarded_x10_mouse_stage,
        => true,
        else => false,
    };
}

pub fn isBareEscapeStage(stage: u8) bool {
    return baseEscapeStage(stage) == 1;
}

pub fn isControlSequenceDiscardStage(stage: u8) bool {
    return baseEscapeStage(stage) == control_sequence_discard_stage;
}

fn resetMouseEscapeDecode(stage: *u8, param: *u16, param2: *u16, mouse: *MouseInput) void {
    stage.* = 0;
    param.* = 0;
    param2.* = 0;
    mouse.reset();
}

fn beginControlSequenceDiscard(
    stage: *u8,
    param: *u16,
    param2: *u16,
    mouse: *MouseInput,
    byte: u8,
) ?InputEscapeAction {
    if (byte >= 0x40 and byte <= 0x7e) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return .ignore;
    }
    if (byte >= 0x20 and byte <= 0x3f) {
        setBaseEscapeStage(stage, control_sequence_discard_stage);
        param.* = 1;
        param2.* = 0;
        mouse.reset();
        return null;
    }
    resetMouseEscapeDecode(stage, param, param2, mouse);
    return .ignore;
}

fn consumeControlSequenceDiscardByte(
    stage: *u8,
    param: *u16,
    param2: *u16,
    mouse: *MouseInput,
    byte: u8,
) ?InputEscapeAction {
    if (byte >= 0x40 and byte <= 0x7e) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return .ignore;
    }
    if (byte < 0x20 or byte > 0x3f) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return .ignore;
    }

    param.* = std.math.add(u16, param.*, 1) catch std.math.maxInt(u16);
    if (param.* >= control_sequence_discard_max_bytes) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return .ignore;
    }
    return null;
}

pub fn beginMouseReportDiscard(stage: *u8, param: *u16, param2: *u16, mouse: *MouseInput) bool {
    const remaining = switch (baseEscapeStage(stage.*)) {
        sgr_mouse_stage,
        sgr_mouse_column_stage,
        sgr_mouse_row_stage,
        => sgr_mouse_max_bytes -| mouse.sgr_bytes,
        legacy_x10_button_stage => 3,
        legacy_x10_column_stage => 2,
        legacy_x10_row_stage => 1,
        else => return false,
    };
    if (remaining == 0) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return true;
    }

    mouse.discard_remaining = remaining;
    param.* = 0;
    param2.* = 0;
    if (isLegacyX10PayloadStage(stage.*)) {
        setBaseEscapeStage(stage, discarded_x10_mouse_stage);
    } else {
        setBaseEscapeStage(stage, discarded_sgr_mouse_stage);
    }
    return true;
}

pub fn consumeMouseReportDiscardByte(
    stage: *u8,
    param: *u16,
    param2: *u16,
    mouse: *MouseInput,
    byte: u8,
) MouseReportDiscardResult {
    std.debug.assert(isMouseReportDiscardStage(stage.*));
    if (byte == 0x1b) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        stage.* = 1;
        return .restart;
    }

    if (baseEscapeStage(stage.*) == discarded_sgr_mouse_stage and (byte == 'M' or byte == 'm')) {
        resetMouseEscapeDecode(stage, param, param2, mouse);
        return .report_end;
    }

    std.debug.assert(mouse.discard_remaining > 0);
    mouse.discard_remaining -= 1;
    if (mouse.discard_remaining != 0) return .pending;

    resetMouseEscapeDecode(stage, param, param2, mouse);
    return .bound;
}

fn noteSgrMouseByte(mouse: *MouseInput) bool {
    if (mouse.sgr_bytes == sgr_mouse_max_bytes) return false;
    mouse.sgr_bytes += 1;
    return true;
}

fn sgrMouseAction(button: u16, column: u16, row: u16, terminator: u8) InputEscapeAction {
    if (column == 0 or row == 0) return .ignore;
    if ((button & 64) != 0) {
        if (terminator != 'M') return .ignore;
        return switch (button & 0b11) {
            0 => .{ .mouse_wheel = .up },
            1 => .{ .mouse_wheel = .down },
            else => .ignore,
        };
    }
    if ((button & 0b11) != 0) return .ignore;

    const kind: MousePointerKind = if (terminator == 'm')
        .release
    else if (terminator == 'M' and (button & 32) != 0)
        .drag
    else if (terminator == 'M')
        .press
    else
        return .ignore;
    return .{ .mouse_pointer = .{
        .kind = kind,
        .column = column,
        .row = row,
        .shift = (button & 4) != 0,
        .alt = (button & 8) != 0,
        .ctrl = (button & 16) != 0,
    } };
}

pub fn consumeInputEscapeByte(stage: *u8, param: *u16, param2: *u16, byte: u8) ?InputEscapeAction {
    var mouse = MouseInput{};
    return consumeInputEscapeByteWithMouse(stage, param, param2, &mouse, byte);
}

pub fn consumeInputEscapeByteWithMouse(
    stage: *u8,
    param: *u16,
    param2: *u16,
    mouse: *MouseInput,
    byte: u8,
) ?InputEscapeAction {
    const base_stage = baseEscapeStage(stage.*);
    if (base_stage == 0) return null;
    if (byte == 0x1b and base_stage != 1 and !isLegacyX10PayloadStage(stage.*)) {
        stage.* = 1;
        param.* = 0;
        param2.* = 0;
        mouse.reset();
        return null;
    }

    switch (base_stage) {
        1 => {
            if (byte == '[') {
                setBaseEscapeStage(stage, 2);
                param.* = 0;
                param2.* = 0;
                mouse.reset();
                return null;
            }
            if (byte == 'O') {
                setBaseEscapeStage(stage, 4);
                param.* = 0;
                param2.* = 0;
                return null;
            }
            if (byte == '\r' or byte == '\n') {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                return .insert_newline;
            }
            if (byte == 'o') {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                // ESC o is Meta-O, not a Ctrl-O terminal report.
                return .ignore;
            }
            if (byte == 'b') {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                return .word_left;
            }
            if (byte == 'f') {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                return .word_right;
            }
            if (byte == 'd') {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                return .{ .composer_shortcut = .delete_word_right };
            }
            if (byte == 0x7f or byte == 0x08) {
                stage.* = 0;
                param.* = 0;
                param2.* = 0;
                return .delete_word_left;
            }
            if (byte == 0x1b) {
                stage.* = escape_meta_mask | 1;
                return null;
            }
            stage.* = 0;
            param.* = 0;
            param2.* = 0;
            return .ignore;
        },
        2 => {
            const meta_prefixed = hasMetaPrefix(stage.*);
            const action: ?InputEscapeAction = switch (byte) {
                'A', 'B', 'C', 'D' => if (meta_prefixed)
                    modifiedArrowAction(byte, 0, true)
                else switch (byte) {
                    'A' => .cursor_up,
                    'B' => .cursor_down,
                    'C' => .cursor_right,
                    'D' => .cursor_left,
                    else => unreachable,
                },
                'H' => .home,
                'F' => .end,
                'Z' => .toggle_permission_mode,
                '<' => {
                    mouse.reset();
                    setBaseEscapeStage(stage, sgr_mouse_stage);
                    return null;
                },
                'M' => {
                    mouse.reset();
                    setBaseEscapeStage(stage, legacy_x10_button_stage);
                    return null;
                },
                '?' => {
                    return beginControlSequenceDiscard(stage, param, param2, mouse, byte);
                },
                '0'...'9' => {
                    param.* = byte - '0';
                    param2.* = 1;
                    setBaseEscapeStage(stage, 3);
                    return null;
                },
                else => return beginControlSequenceDiscard(stage, param, param2, mouse, byte),
            };
            stage.* = 0;
            param.* = 0;
            param2.* = 0;
            return action;
        },
        control_sequence_discard_stage => {
            return consumeControlSequenceDiscardByte(stage, param, param2, mouse, byte);
        },
        3 => {
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(param, byte);
                if (param2.* < std.math.maxInt(u16)) param2.* += 1;
                return null;
            }

            if (byte == ';') {
                param2.* = param.*;
                param.* = 0;
                setBaseEscapeStage(stage, 5);
                return null;
            }

            if (byte == 'u') {
                const meta_prefixed = hasMetaPrefix(stage.*);
                const value = param.*;
                resetMouseEscapeDecode(stage, param, param2, mouse);
                // Single-parameter CSI u: no `;`, so modifiers == 0.
                return kittyUnicodeKeyAction(value, 0, meta_prefixed);
            }
            // A `_` terminator here is a win32-input-mode report with only the
            // VK parameter present; later fields arrive in the dedicated stage.
            if (byte == '_') {
                mouse.win32_vk = param.*;
                mouse.win32_field = win32_scan_field;
                setBaseEscapeStage(stage, win32_input_field_stage);
                param.* = 0;
                return null;
            }
            if (byte != '~') return beginControlSequenceDiscard(stage, param, param2, mouse, byte);

            const value = param.*;
            const digit_count = param2.*;
            resetMouseEscapeDecode(stage, param, param2, mouse);
            if (digit_count == 3 and value == 200) return .paste_start;
            if (digit_count == 3 and value == 201) return .paste_end;

            return switch (value) {
                1, 7 => .home,
                3 => .delete_next,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .ignore,
            };
        },
        4 => {
            const meta_prefixed = hasMetaPrefix(stage.*);
            const action: InputEscapeAction = switch (byte) {
                'A', 'B', 'C', 'D' => if (meta_prefixed)
                    modifiedArrowAction(byte, 0, true) orelse .ignore
                else switch (byte) {
                    'A' => .cursor_up,
                    'B' => .cursor_down,
                    'C' => .cursor_right,
                    'D' => .cursor_left,
                    else => unreachable,
                },
                'H' => .home,
                'F' => .end,
                else => return beginControlSequenceDiscard(stage, param, param2, mouse, byte),
            };
            resetMouseEscapeDecode(stage, param, param2, mouse);
            return action;
        },
        5 => {
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(param, byte);
                return null;
            }

            if (byte == ';') {
                // Stash the first parameter so a win32-input-mode report can
                // reach the collector stage with its VK intact; kitty paths
                // never read the scratch field and reset it on termination.
                mouse.win32_vk = param2.*;
                param2.* = param.*;
                param.* = 0;
                setBaseEscapeStage(stage, 6);
                return null;
            }

            // Two params then `_`: win32-input-mode with VK and scan code.
            if (byte == '_') {
                mouse.win32_vk = param2.*;
                mouse.win32_scan = param.*;
                mouse.win32_field = win32_char_field;
                setBaseEscapeStage(stage, win32_input_field_stage);
                param.* = 0;
                param2.* = 0;
                return null;
            }

            // Ghostty can report a Kitty key event type as a colon-qualified
            // modifier, e.g. `ESC[27;1:1u` for an Escape key press.
            if (byte == ':' and param2.* == 27) {
                param2.* = if (param.* > 0) param.* - 1 else 0;
                param.* = 0;
                setBaseEscapeStage(stage, kitty_escape_event_type_stage);
                return null;
            }

            if (byte == 'u') {
                const meta_prefixed = hasMetaPrefix(stage.*);
                const keycode = param2.*;
                const modifiers = if (param.* > 0) param.* - 1 else 0;
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return kittyUnicodeKeyAction(keycode, modifiers, meta_prefixed);
            }

            if (byte == '~') {
                const keycode = param2.*;
                const modifiers = if (param.* > 0) param.* - 1 else 0;
                resetMouseEscapeDecode(stage, param, param2, mouse);
                if (keycode == 3 and (modifiers & 0x08) != 0) {
                    return .delete_to_line_end;
                }
                if (keycode == 3 and ((modifiers & 0x02) != 0 or (modifiers & 0x04) != 0)) {
                    return .delete_word_right;
                }
                if (modifiers != 0) return switch (keycode) {
                    1, 7 => composerMove(
                        if ((modifiers & ctrl_modifier) != 0) .draft_start else .line_start,
                        modifiers,
                    ),
                    4, 8 => composerMove(
                        if ((modifiers & ctrl_modifier) != 0) .draft_end else .line_end,
                        modifiers,
                    ),
                    5 => composerMove(.page_up, modifiers),
                    6 => composerMove(.page_down, modifiers),
                    else => .ignore,
                };
                return switch (keycode) {
                    1, 7 => .home,
                    3 => .delete_next,
                    4, 8 => .end,
                    5 => .page_up,
                    6 => .page_down,
                    else => .ignore,
                };
            }

            const meta_prefixed = hasMetaPrefix(stage.*);
            const modifiers = if (param.* > 0) param.* - 1 else 0;
            if (byte == 'Z' and modifiers != 0) {
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return .toggle_permission_mode;
            }
            if (modifiedArrowAction(byte, modifiers, meta_prefixed)) |action| {
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return action;
            }

            const action: InputEscapeAction = switch (byte) {
                'A' => .cursor_up,
                'B' => .cursor_down,
                'C' => .cursor_right,
                'D' => .cursor_left,
                'H' => .home,
                'F' => .end,
                else => return beginControlSequenceDiscard(stage, param, param2, mouse, byte),
            };
            resetMouseEscapeDecode(stage, param, param2, mouse);
            return action;
        },
        // Stage 6: third parameter (e.g. modifyOtherKeys: ESC[27;modifier;keycode~)
        6 => {
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(param, byte);
                return null;
            }

            if (byte == '~') {
                const meta_prefixed = hasMetaPrefix(stage.*);
                const keycode = param.*;
                const modifiers = if (param2.* > 0) param2.* - 1 else 0;
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return kittyUnicodeKeyAction(keycode, modifiers, meta_prefixed);
            }

            // Three params then `;`: a win32-input-mode report continues into
            // the collector stage with its remaining fields.
            if (byte == ';') {
                mouse.win32_scan = param2.*;
                mouse.win32_char = param.*;
                mouse.win32_field = win32_key_down_field;
                setBaseEscapeStage(stage, win32_input_field_stage);
                param.* = 0;
                param2.* = 0;
                return null;
            }

            // Three params then `_`: a truncated win32-input-mode press with
            // no modifier state.
            if (byte == '_') {
                const action = win32InputKeyAction(mouse.win32_vk, param.*, 1, 0);
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return action;
            }

            return beginControlSequenceDiscard(stage, param, param2, mouse, byte);
        },
        // Kitty key reports with an event type: `ESC[27;modifier:event-type u`.
        // Only press and repeat are actionable; release must not close a panel.
        kitty_escape_event_type_stage => {
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(param, byte);
                return null;
            }
            if (byte == 'u') {
                const modifiers = param2.*;
                const event_type = param.*;
                resetMouseEscapeDecode(stage, param, param2, mouse);
                if (event_type == 1 or event_type == 2) {
                    return kittyUnicodeKeyAction(27, modifiers, false);
                }
                return .ignore;
            }
            return beginControlSequenceDiscard(stage, param, param2, mouse, byte);
        },
        // win32-input-mode field collector: entered from the CSI param stages
        // once a report has more parameters than kitty uses, and terminated by
        // `_`. Fields land in MouseInput scratch in wire order.
        win32_input_field_stage => {
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(param, byte);
                return null;
            }
            if (byte == ';') {
                storeWin32Field(mouse, param.*);
                param.* = 0;
                return null;
            }
            if (byte == '_') {
                storeWin32Field(mouse, param.*);
                const action = win32InputKeyAction(
                    mouse.win32_vk,
                    mouse.win32_char,
                    mouse.win32_key_down,
                    mouse.win32_state,
                );
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return action;
            }
            return beginControlSequenceDiscard(stage, param, param2, mouse, byte);
        },
        // SGR mouse: ESC [ < button ; column ; row M/m.
        sgr_mouse_stage => {
            if (!noteSgrMouseByte(mouse) or mouse.sgr_bytes == sgr_mouse_max_bytes) {
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return .ignore;
            }
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(&mouse.button, byte);
                return null;
            }
            if (byte == ';') {
                setBaseEscapeStage(stage, sgr_mouse_column_stage);
                return null;
            }
            resetMouseEscapeDecode(stage, param, param2, mouse);
            return .ignore;
        },
        sgr_mouse_column_stage => {
            if (!noteSgrMouseByte(mouse) or mouse.sgr_bytes == sgr_mouse_max_bytes) {
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return .ignore;
            }
            if (byte >= '0' and byte <= '9') {
                appendCsiDigitSaturating(&mouse.column, byte);
                return null;
            }
            if (byte == ';') {
                setBaseEscapeStage(stage, sgr_mouse_row_stage);
                return null;
            }
            resetMouseEscapeDecode(stage, param, param2, mouse);
            return .ignore;
        },
        sgr_mouse_row_stage => {
            if (!noteSgrMouseByte(mouse)) {
                resetMouseEscapeDecode(stage, param, param2, mouse);
                return .ignore;
            }
            if (byte >= '0' and byte <= '9') {
                if (mouse.sgr_bytes == sgr_mouse_max_bytes) {
                    resetMouseEscapeDecode(stage, param, param2, mouse);
                    return .ignore;
                }
                appendCsiDigitSaturating(&mouse.row, byte);
                return null;
            }

            const button = mouse.button;
            const column = mouse.column;
            const row = mouse.row;
            resetMouseEscapeDecode(stage, param, param2, mouse);
            return sgrMouseAction(button, column, row, byte);
        },
        legacy_x10_button_stage => {
            mouse.button = byte;
            setBaseEscapeStage(stage, legacy_x10_column_stage);
            return null;
        },
        legacy_x10_column_stage => {
            mouse.column = byte;
            setBaseEscapeStage(stage, legacy_x10_row_stage);
            return null;
        },
        legacy_x10_row_stage => {
            const button = mouse.button;
            stage.* = 0;
            param.* = 0;
            param2.* = 0;
            mouse.reset();
            if (button < 32) return .ignore;
            const normalized_button = button - 32;
            if ((normalized_button & 64) == 0) return .ignore;
            return switch (normalized_button & 0b11) {
                0 => .{ .mouse_wheel = .up },
                1 => .{ .mouse_wheel = .down },
                else => .ignore,
            };
        },
        else => {
            stage.* = 0;
            param.* = 0;
            param2.* = 0;
            return null;
        },
    }
}

fn feedWin32Report(report: []const u8) InputEscapeAction {
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;
    var mouse = MouseInput{};
    var action: ?InputEscapeAction = null;
    for (report) |byte| {
        action = consumeInputEscapeByteWithMouse(&stage, &param, &param2, &mouse, byte);
    }
    return action.?;
}

test "win32-input-mode Enter press decodes to carriage return and release to ignore" {
    try std.testing.expectEqual(
        InputEscapeAction{ .remapped_byte = '\r' },
        feedWin32Report("[13;28;13;1;0;1_"),
    );
    try std.testing.expectEqual(
        InputEscapeAction.ignore,
        feedWin32Report("[13;28;13;0;0;1_"),
    );
}

test "win32-input-mode Ctrl+Enter decodes to steer submit" {
    try std.testing.expectEqual(
        InputEscapeAction.steer_submit,
        feedWin32Report("[13;28;10;1;8;1_"),
    );
}

test "win32-input-mode Shift+Enter decodes to insert newline" {
    try std.testing.expectEqual(
        InputEscapeAction.insert_newline,
        feedWin32Report("[13;28;13;1;16;1_"),
    );
}

test "win32-input-mode arrows and Escape decode to navigation actions" {
    try std.testing.expectEqual(InputEscapeAction.cursor_up, feedWin32Report("[38;72;0;1;0;1_"));
    try std.testing.expectEqual(InputEscapeAction.cursor_down, feedWin32Report("[40;80;0;1;0;1_"));
    try std.testing.expectEqual(InputEscapeAction.cursor_left, feedWin32Report("[37;75;0;1;0;1_"));
    try std.testing.expectEqual(InputEscapeAction.cursor_right, feedWin32Report("[39;77;0;1;0;1_"));
    try std.testing.expectEqual(InputEscapeAction.escape, feedWin32Report("[27;1;27;1;0;1_"));
}

test "win32-input-mode Ctrl+C decodes to control byte 3" {
    const action = feedWin32Report("[67;46;3;1;8;1_");
    try std.testing.expectEqual(@as(u8, 3), action.remapped_byte);
}

test "win32-input-mode printable character decodes to its character" {
    const action = feedWin32Report("[65;30;97;1;0;1_");
    try std.testing.expectEqual(@as(u8, 'a'), action.remapped_byte);
}

test "win32-input-mode Backspace decodes to 127" {
    const action = feedWin32Report("[8;14;8;1;0;1_");
    try std.testing.expectEqual(@as(u8, 127), action.remapped_byte);
}
