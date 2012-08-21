###
Copyright 2012 David Mauro

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Keypress is a robust keyboard input capturing Javascript utility
focused on input for games.

version 1.0.0
###

###
Options available and defaults:
    keys            : []            - An array of the keys pressed together to activate combo
    count           : 0             - The number of times a counting combo has been pressed. Reset on release.
    allow_default   : false         - Allow the default key event to happen in addition to the combo.
    is_ordered      : false         - Unless this is set to true, the keys can be pressed down in any order
    is_counting     : false         - Makes this a counting combo (see documentation)
    is_sequence     : false         - Rather than a key combo, this is an ordered key sequence
    prevent_repeat  : false         - Prevent the combo from repeating when keydown is held.
    on_keyup        : null          - A function that is called when the combo is released
    on_keydown      : null          - A function that is called when the combo is pressed.
    on_release      : null          - A function that is called for counting combos when all keys are released.
    this            : undefined     - The scope for this of your callback functions
###

_ready = false
_registered_combos = []
_sequence = []
_sequence_timer = null
window.keys_down = _keys_down = []
window.active_combos = _active_combos = []
_prevent_capture = false
_event_classname = "keypress_events"
_metakey = "ctrl"
_modifier_keys = ["meta", "alt", "option", "ctrl", "shift", "cmd"]
_valid_keys = []
_combo_defaults = {
    keys            : []
    count           : 0
    test            : "hello"
}

_log_error = (msg) ->
    console.log msg

_compare_arrays = (a1, a2) ->
    # This will ignore the ordering of the arrays
    # and simply check if they have the same contents.
    return false unless a1.length is a2.length
    for item in a1
        continue if item in a2
        return false
    for item in a2
        continue if item in a1
        return false
    return true

_prevent_default = (e) ->
    # If we've pressed a combo, or if we are working towards
    # one, we should prevent the default keydown event.
    e.preventDefault()

_allow_key_repeat = (combo) ->
    return false if combo.prevent_repeat
    # Combos with keydown functions should be able to rapid fire
    # when holding down the key for an extended period
    return true if typeof combo.on_keydown is "function"

_keys_remain = (combo) ->
    for key in combo.keys
        if key in _keys_down
            keys_remain = true
            break
    return keys_remain

_fire = (event, combo, key_event) ->
    # Only fire this event if the function is defined
    if typeof combo["on_" + event] is "function"
        if event is "release"
            if combo["on_" + event].call(combo.this, key_event, combo.count) is false
                _prevent_default key_event
            combo.count = 0
        else
            if combo["on_" + event].call(combo.this, key_event) is false
                _prevent_default key_event
    # We need to mark that keyup has already happened
    if event is "keyup"
        combo.keyup_fired = true

_match_combo_arrays = (potential_match, source_combo_array, allow_partial_match=false) ->
    for source_combo in source_combo_array
        continue if source_combo_array.is_sequence
        if source_combo.is_ordered
            return source_combo if potential_match.join("") is source_combo.keys.join("")
            return source_combo if allow_partial_match and potential_match.join("") is source_combo.keys.slice(0, potential_match.length).join("")
        else
            return source_combo if _compare_arrays potential_match, source_combo.keys
            return source_combo if allow_partial_match and _compare_arrays potential_match, source_combo.keys.slice(0, potential_match.length)
    return false

_cmd_bug_check = (combo_keys) ->
    # We don't want to allow combos to activate if the cmd key
    # is pressed, but cmd isn't in them. This is so they don't
    # accidentally rapid fire due to our hack-around for the cmd
    # key bug and having to fake keyups.
    if "cmd" in _keys_down and "cmd" not in combo_keys
        return false
    return true

_get_active_combo = (key) ->
    # Based on the keys_down and the key just pressed or released
    # (which should not be in keys_down), we determine if any
    # combo in registered_combos matches exactly.

    # First check that every key in keys_down maps to a combo
    keys_down = _keys_down.filter (down_key) ->
        down_key isnt key
    keys_down.push key
    perfect_match = _match_combo_arrays keys_down, _registered_combos
    return perfect_match if perfect_match and _cmd_bug_check keys_down

    # Then work our way back through a combination with each other key down in order
    # This will match a combo even if some other key that is not part of the combo
    # is being held down.
    potentials = []
    slice_up_array = (array) ->
        for i in [0...array.length]
            partial = array.slice()
            partial.splice i, 1
            continue unless partial.length
            fuzzy_match = _match_combo_arrays partial, _registered_combos
            potentials.push(fuzzy_match) if fuzzy_match and fuzzy_match not in potentials
            slice_up_array partial
        return
    slice_up_array keys_down

    return false unless potentials.length

    # Return the combo that includes key in the keys array.
    # If multiple include it, return the longest one, if they
    # are the same length, announce a conflict.
    check_for_conflict = (array) ->
        if array.length > 1 and array[0].keys.length is array[1].keys.length
            _log_error "Conflicting combos registered"
            return true

    if potentials.length > 1
        potentials.sort (a, b) ->
            b.keys.length - a.keys.length
        better_pots = []
        for potential in potentials
            better_pots.push(potential) if key in potential.keys

        # If at least one potential contains key
        if better_pots.length
            return false if check_for_conflict better_pots
            potentials = better_pots
        # If none of the potentials contain key
        else
            return false if check_for_conflict potentials

    return false unless potentials.length
    return potentials[0] if _cmd_bug_check potentials[0].keys

_get_potential_combos = (key) ->
    # Check if we are working towards pressing a combo.
    # Used for preventing default on keys that might match
    # to a combo in the future.
    potentials = []
    for combo in _registered_combos
        continue if combo.is_sequence
        potentials.push(combo) if key in combo.keys and _cmd_bug_check combo.keys
    return potentials

_add_to_active_combos = (combo) ->
    replaced = false
    # An active combo is any combo which the user has already entered.
    # We use this to track when a user has released the last key of a
    # combo for on_release, and to keep combos from 'overlapping'.
    if combo in _active_combos
        return false
    else if _active_combos.length
        # We have to check if we're replacing another active combo
        # So compare the combo.keys to all active combos' keys.
        for i in [0..._active_combos.length]
            active_keys = _active_combos[i].keys.slice()
            for active_key in active_keys
                is_match = true
                unless active_key in combo.keys
                    is_match = false
                    break
            if is_match
                # In this case we'll just replace it
                _active_combos.splice i, 1, combo
                replaced = true
                break
    unless replaced
        _active_combos.unshift combo
    return true

_remove_from_active_combos = (combo) ->
    for i in [0..._active_combos.length]
        active_combo = _active_combos[i]
        if active_combo is combo
            _active_combos.splice i, 1
            break
    return

_add_key_to_sequence = (key, e) ->
    _sequence.push key
    # Now check if they're working towards a sequence
    sequence_combos = _get_possible_sequences()
    if sequence_combos.length
        for combo in sequence_combos
            _prevent_default(e) unless combo.allow_default
        # If we're working towards one, give them more time to keep going
        clearTimeout(_sequence_timer) if _sequence_timer
        _sequence_timer = setTimeout ->
            _sequence = []
        , 800
    else
        # If we're not working towards something, just clear it out
        _sequence = []
    return

_get_possible_sequences = ->
    # Determine what if any sequences we're working towards.
    # We will consider any which any part of the end of the sequence
    # matches and return all of them.
    matches = []
    for combo in _registered_combos
        for j in [1.._sequence.length]
            sequence = _sequence.slice -j
            continue unless combo.is_sequence
            unless "shift" in combo.keys
                sequence = sequence.filter (key) ->
                    return key isnt "shift"
                continue unless sequence.length
            for i in [0...sequence.length]
                if combo.keys[i] is sequence[i]
                    match = true
                else
                    match = false
                    break
            matches.push(combo) if match
    return matches

_get_sequence = (key) ->
    # Compare _sequence to all combos
    for combo in _registered_combos
        continue unless combo.is_sequence
        for j in [1.._sequence.length]
            # As we are traversing backwards through the sequence keys,
            # Take out any shift keys, unless shift is in the combo.
            sequence = _sequence.filter((seq_key) ->
                return true if "shift" in combo.keys
                return seq_key isnt "shift"
            ).slice -j
            continue unless combo.keys.length is sequence.length
            for i in [0...sequence.length]
                seq_key = sequence[i]
                # Special case for shift. Ignore shift keys, unless the sequence explicitly uses them
                continue if seq_key is "shift" unless "shift" in combo.keys
                # Don't select this combo if we're pressing shift and shift isn't in it
                continue if key is "shift" and "shift" not in combo.keys
                if combo.keys[i] is seq_key
                    match = true
                else
                    match = false
                    break
        return combo if match
    return false

_convert_to_shifted_key = (key, e) ->
    return false unless e.shiftKey
    k = _keycode_shifted_keys[key]
    return k if k?
    return false

_key_down = (key, e) ->
    # Check if we're holding shift
    shifted_key = _convert_to_shifted_key key, e
    key = shifted_key if shifted_key

    # Add the key to sequences
    _add_key_to_sequence key, e
    sequence_combo = _get_sequence key
    _fire("keydown", sequence_combo, e) if sequence_combo

    # We might have modifier keys down when coming back to
    # this window and they might now be in _keys_down, so
    # we're doing a check to make sure we put it back in.
    # This only works for explicit modifier keys.
    for mod, event_mod of _modifier_event_mapping
        continue unless e[event_mod]
        mod = _metakey if mod is "meta"
        continue if mod is key or mod in _keys_down
        _keys_down.push mod

    # Find which combo we have pressed or might be working towards, and prevent default
    combo = _get_active_combo key
    if combo and !combo.allow_default
        _prevent_default e
    potential_combos = _get_potential_combos key
    if potential_combos.length
        for potential in potential_combos
            if !potential.allow_default
                _prevent_default e

    # If we've already pressed this key, check that we want to fire
    # again, otherwise just add it to the keys_down list.
    if key in _keys_down
        return false unless _allow_key_repeat combo
    else
        _keys_down.push key

    # We're done now unless we have a match
    return false unless combo

    # Now we add this combo or replace it in _active_combos
    _add_to_active_combos combo, key

    # We reset the keyup_fired property because you should be
    # able to fire that again, if you've pressed the key down again
    combo.keyup_fired = false

    # Now we fire the keydown event
    _fire "keydown", combo, e
    if combo.is_counting and typeof combo.on_keydown is "function"
        combo.count += 1

    return

_key_up = (key, e) ->
    # Check if we're holding shift
    unshifted_key = key
    shifted_key = _convert_to_shifted_key key, e
    key = shifted_key if shifted_key
    shifted_key = _keycode_shifted_keys[unshifted_key]

    # Check if we have a keyup firing
    sequence_combo = _get_sequence key
    _fire("keyup", sequence_combo, e) if sequence_combo

    # Remove from the list, careful of shift conflicts
    return false unless key in _keys_down or unshifted_key in _keys_down or shifted_key in _keys_down
    for i in [0..._keys_down.length]
        if _keys_down[i] in [key, shifted_key, unshifted_key]
            _keys_down.splice i, 1
            break

    # When releasing we should only check if we
    # match from _active_combos so that we don't
    # accidentally fire for a combo that was a
    # smaller part of the one we actually wanted.
    for active_combo in _active_combos
        if key in active_combo.keys
            combo = active_combo
            break
    return unless combo

    # Check if any keys from this combo are still being held.
    keys_remaining = _keys_remain combo

    # Any unactivated combos will fire, unless it is a counting combo with no keys remaining.
    # We don't fire those because they will fire on_release on their last key release.
    if !combo.keyup_fired and (!combo.is_counting or (combo.is_counting and keys_remaining))
        _fire "keyup", combo, e
        # Dont' add to the count unless we only have a keyup callback
        if combo.is_counting and typeof combo.on_keyup is "function" and typeof combo.on_keydown isnt "function"
            combo.count += 1 

    # Store this for later cleanup
    active_combos_length = _active_combos.length

    # If this was the last key released of the combo, clean up.
    unless keys_remaining
        if combo.is_counting
            _fire "release", combo, e
        _remove_from_active_combos combo

    # We also need to check other combos that might still be in active_combos
    # and needs to be removed from it.
    if active_combos_length > 1
        for active_combo in _active_combos
            continue if combo is active_combo or active_combo is undefined
            unless _keys_remain active_combo
                _remove_from_active_combos active_combo
    return

_receive_input = (e, is_keydown) ->
    # If we're not capturing input, we should
    # clear out _keys_down for good measure
    if _prevent_capture
        if _keys_down.length
            _keys_down = []
        return
    # Catch tabbing out of a non-capturing state
    if !is_keydown and !_keys_down.length
        return
    key = _convert_key_to_readable e.keyCode
    return unless key
    if is_keydown
        _key_down key, e
    else
        _key_up key, e

_unregister_combo = (combo) ->
    for i in [0..._registered_combos.length]
        if combo is _registered_combos[i]
            _registered_combos.splice i, 1
            break

_validate_combo = (combo) ->
    # Convert "meta" to either "ctrl" or "cmd"
    # Don't explicity use the command key, it breaks
    # because it is the windows key in Windows, and
    # cannot be hijacked.
    for i in [0...combo.keys.length]
        key = combo.keys[i]
        # Check the name and replace if needed
        alt_name = _keycode_alternate_names[key]
        key = combo.keys[i] = alt_name if alt_name
        if key is "meta" or key is "cmd"
            combo.keys.splice i, 1, _metakey
            if key is "cmd"
                _log_error "Warning: use the \"meta\" key rather than \"cmd\" for Windows compatibility"

    # Check that all keys in the combo are valid
    for key in combo.keys
        unless key in _valid_keys
            _log_error "Do not recognize the key \"#{key}\""
            return false

    # Make sure the combo isn't already registered
    for registered_combo in _registered_combos
        if _compare_arrays combo.keys, registered_combo.keys
            _log_error "Warning: we're overwriting another combo"
            _unregister_combo registered_combo
            break

    # We can only allow a single non-modifier key
    # in combos that include the command key (this
    # includes 'meta') because of the keyup bug.
    if "meta" in combo.keys or "cmd" in combo.keys
        non_modifier_keys = combo.keys.slice()
        for mod_key in _modifier_keys
            if (i = non_modifier_keys.indexOf(mod_key)) > -1
                non_modifier_keys.splice(i, 1) 
        if non_modifier_keys.length > 1
            _log_error "META and CMD key combos cannot have more than 1 non-modifier keys", combo, non_modifier_keys
            return true
    return true

_decide_meta_key = ->
    # If the useragent reports Mac OS X, assume cmd is metakey
    if navigator.userAgent.indexOf("Mac OS X") != -1
        _metakey = "cmd"
    return

_bug_catcher = (e) ->
    # Force a keyup for non-modifier keys when command is held because they don't fire
    if "cmd" in _keys_down and _convert_key_to_readable(e.keyCode) not in ["cmd", "shift", "alt"]
        _receive_input e, false

_change_keycodes_by_browser = ->
    if navigator.userAgent.indexOf("Opera") != -1
        # Opera does weird stuff with command and control keys, let's fix that.
        # Note: Opera cannot override meta + s browser default of save page.
        # Note: Opera does some really strange stuff when cmd+alt+shift
        # are held and a non-modifier key is pressed.
        _keycode_dictionary["17"] = "cmd"
    return

###########################
# Public object and methods
###########################
window.keypress = {}

keypress.init = ()->
    # Let us reset by calling init again
    if _ready
        _registered_combos = []
        return
    
    _decide_meta_key()
    _change_keycodes_by_browser()
    document.body.onkeydown = (e) ->
        _receive_input e, true
        _bug_catcher e
    document.body.onkeyup = (e) ->
        _receive_input e, false
    window.onblur = ->
        # This prevents alt+tab conflicts
        _keys_down = []
        _valid_combos = []
    _ready = true

keypress.combo = (keys, callback, allow_default=false) ->
    # Shortcut for simple combos.
    keypress.register_combo(
        keys            : keys
        on_keydown      : callback
        allow_default   : allow_default
    )

keypress.keyup_combo = (keys, callback, allow_default=false) ->
    keypress.register_combo(
        keys            : keys
        on_keyup        : callback
        allow_default   : allow_default
    )

keypress.counting_combo = (keys, count_callback, release_callback, allow_default=false) ->
    # Shortcut for counting combos
    keypress.register_combo(
        keys            : keys
        is_counting     : true
        is_ordered      : true
        on_keydown      : count_callback
        on_release      : release_callback
        allow_default   : allow_default
    )

keypress.sequence = (keys, callback, allow_default=false) ->
    keypress.register_combo(
        keys            : keys
        on_keydown      : callback
        is_sequence     : true
        allow_default   : allow_default
    )

keypress.register_combo = (combo) ->
    if typeof combo.keys is "string"
        combo.keys = combo.keys.split " "
    for own property, value of _combo_defaults
        combo[property] = value unless combo[property]?
    if _validate_combo combo
        _registered_combos.push combo
        return true

keypress.unregister_combo = (keys) ->
    for combo in _registered_combos
        if _compare_arrays keys, combo.keys
            _unregister_combo combo

keypress.listen = ->
    _prevent_capture = false

keypress.stop_listening = ->
    _prevent_capture = true

_convert_key_to_readable = (k) ->
    return _keycode_dictionary[k]

_modifier_event_mapping =
    "meta"  : "metaKey"
    "ctrl"  : "ctrlKey"
    "shift" : "shiftKey"
    "alt"   : "altKey"

_keycode_alternate_names =
    "control"   : "ctrl"
    "command"   : "cmd"
    "break"     : "pause"
    "windows"   : "cmd"
    "option"    : "alt"

_keycode_shifted_keys =
    "/"     : "?"
    "."     : ">"
    ","     : "<"
    "\'"    : "\""
    ";"     : ":"
    "["     : "{"
    "]"     : "}"
    "\\"    : "|"
    "`"     : "~"
    "="     : "+"
    "-"     : "_"
    "1"     : "!"
    "2"     : "@"
    "3"     : "#"
    "4"     : "$"
    "5"     : "%"
    "6"     : "^"
    "7"     : "&"
    "8"     : "*"
    "9"     : "("
    "0"     : ")"

_keycode_dictionary = 
    0   : "\\"          # Firefox reports this keyCode when shift is held
    8   : "backspace"
    9   : "tab"
    13  : "enter"
    16  : "shift"
    17  : "ctrl"
    18  : "alt"
    19  : "pause"
    20  : "caps"
    27  : "escape"
    32  : "space"
    33  : "pageup"
    34  : "pagedown"
    35  : "end"
    36  : "home"
    37  : "left"
    38  : "up"
    39  : "right"
    40  : "down"
    45  : "insert"
    46  : "delete"
    48  : "0"
    49  : "1"
    50  : "2"
    51  : "3"
    52  : "4"
    53  : "5"
    54  : "6"
    55  : "7"
    56  : "8"
    57  : "9"
    65  : "a"
    66  : "b"
    67  : "c"
    68  : "d"
    69  : "e"
    70  : "f"
    71  : "g"
    72  : "h"
    73  : "i"
    74  : "j"
    75  : "k"
    76  : "l"
    77  : "m"
    78  : "n"
    79  : "o"
    80  : "p"
    81  : "q"
    82  : "r"
    83  : "s"
    84  : "t"
    85  : "u"
    86  : "v"
    87  : "w"
    88  : "x"
    89  : "y"
    90  : "z"
    91  : "cmd"
    92  : "cmd"
    93  : "cmd"
    106 : "num_multiply"
    107 : "num_add"
    108 : "num_enter"
    109 : "num_subtract"
    110 : "num_decimal"
    111 : "num_divide"
    186 : ";"
    187 : "="
    188 : ","
    189 : "-"
    190 : "."
    191 : "/"
    192 : "`"
    219 : "["
    220 : "\\"
    221 : "]"
    222 : "\'"
    224 : "cmd"
    57392   : "ctrl"    # Opera weirdness

for _, key of _keycode_dictionary
    _valid_keys.push key
for _, key of _keycode_shifted_keys
    _valid_keys.push key
