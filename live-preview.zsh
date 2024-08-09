# live preview

zmodload zsh/datetime
zmodload zsh/zpty
zmodload zsh/mathfunc

LIVE_PREVIEW_ID="live_preview_id_$$"

declare -A live_preview_config
# input debounce in seconds; the live preview will not update until this interval has passed with no keys pressed
live_preview_config[debounce]=0.1
# command timeout in seconds
live_preview_config[timeout]=10
# height of the preview in lines; if this is < 1, then it is as a fraction of the terminal height
live_preview_config[height]=0.9
# maximum number of bytes to read from the command output
live_preview_config[char_limit]=100000
# highlight commands that failed; this is used with region_highlight; set to empty string to disable
live_preview_config[highlight_failed_command]='bg=#330000'
# dim the preview ie \x1b[2m
live_preview_config[dim]=1
# additional message to show if the command fails; this is a printf-style string; %s is replaced with the exit code
live_preview_config[failed_message]=$'\x1b[31mCommand failed with exit status %s\x1b[0m'
# whether to show the border/header of the main preview pane
live_preview_config[show_main_border]=0
# whether to show the pane of the last succesful output if you also have a saved output
live_preview_config[show_last_success_if_saved]=1
# ellipsis string; used when the output overflows
live_preview_config[ellipsis]='…'
# enable scrolling with the mouse using SGR mouse events; MUST have https://github.com/lincheney/live-preview.zsh
live_preview_config[enable_mouse]=0
# use natural scrolling
live_preview_config[mouse_natural_scrolling]=0

# border characeter
live_preview_config[border]='━'
# the start of the border; by default this is the border char repeated 4 times
live_preview_config[border_start]='${(pl:4::$border:)}'
# the end of the border; by default this fills up the rest of the line with the border char
live_preview_config[border_end]='${(pl:$COLUMNS::$border:)}'
# colour of the border of the main pane; use prompt escapes here
live_preview_config[border_main_colour]='%F{13}%B'
# colour of the border of the saved output pane; use prompt escapes here
live_preview_config[border_saved_colour]='%F{3}%B'
# colour of the border of the last success pane; use prompt escapes here
live_preview_config[border_success_colour]='%F{2}%B'
# label of the border of the main pane; use prompt escapes here
live_preview_config[border_main_label]='%S preview: %-5<$ellipsis<$command<< %s'
# label of the border of the saved output pane; use prompt escapes here
live_preview_config[border_saved_label]='%S saved: %-5<$ellipsis<$command%<< %s'
# label of the border of the last success pane; use prompt escapes here
live_preview_config[border_success_label]='%S last success: %-5<$ellipsis<$command%<< %s'

declare -A live_preview_vars=(
    [active]=
    [running]=
    [cache]=

    [active_panes]=

    [main_preview]=
    [main_code]=
    [main_command]=
    [main_scroll]=
    [main_height]=

    [success_preview]=
    [success_code]=
    [success_command]=
    [success_scroll]=
    [success_height]=

    [saved_preview]=
    [saved_code]=
    [saved_command]=
    [saved_scroll]=
    [saved_height]=
)

live_preview.get_height() {
    local __h="${live_preview_config[height]}"
    # calc preview height if fraction
    __h="$(( __h < 1 ? int(LINES * __h) : __h ))"
    __h="$(( __h > LINES-2 ? LINES-2 : __h ))"
    printf -v "$1" %i "$__h"
}

live_preview.worker() (
    emulate -LR zsh

    stty -onlcr -inlcr
    local prev=
    local old_buffer=

    # remove unhandled escapes
    local sed_script='s/\x1b[ #%()*+].//; s/\x1b[^[]//g; s/\x1b\[[?>=!]\?[0-9:;]*[^0-9:;m]//g'
    if (( live_preview_config[dim] )); then
        # and make it dim
        sed_script+='; s/\x1b\[[0-9:;]*/&;2/g'
    fi

    # wait for a line
    while IFS= read -r line; do

        while true; do
            # read until the last available
            while IFS= read -t0 -r line; do :; done
            eval "$line"
            () {
                set -o localoptions -o extendedglob
                BUFFER="${BUFFER%%[[:blank:]]#}" # remove trailing space
                BUFFER="${BUFFER%%[[:blank:]]#|[[:blank:]]#while}" # remove trailing | while; this causes infinite loop
                BUFFER="${BUFFER%%[[:blank:]]#|}" # remove trailing |
            }
            if [[ "$BUFFER" == "$old_buffer" ]]; then
                break
            fi

            old_buffer="$BUFFER"
            # debounce
            sleep "${live_preview_config[debounce]}"
        done

        # input has not changed
        if [[ "$BUFFER" == "$prev" ]]; then
            printf 'code=nochange; data=\n'
            continue
        fi
        prev="$BUFFER"

        # input is all whitespace
        # (it's probably just all blank though? since whitespace is stripped above)
        if [[ "$BUFFER" =~ ^\\s*$ ]]; then
            printf 'code=0; data=\n'
            continue
        fi

        live_preview.get_height height

        (
            exec 2>&1
            coproc (
                # need to close the coproc in the coproc as well
                coproc true

                name="$RANDOM"
                script='
stty -onlcr -inlcr
stty columns $COLUMNS
stty rows $LINES
exec 0</dev/null
setopt localtraps
trap "rc=\$?; echo; echo -n \$rc" EXIT
eval "$BUFFER"
'
                # fake pty to get colours
                if zpty "$name" "$script"; then
                    fd="$REPLY"
                    while IFS= read -u "$fd" -r line; do
                        printf %s\\n "$line"
                    done
                    # the exit code is the last *partial* line
                    exit "$line"
                fi
                exit 127
            )

            coproc_pid="$!"
            # use head to truncate the lines
            timeout "${live_preview_config[timeout]}" cat <&p \
            | head -c "${live_preview_config[char_limit]}"

            # this has the effect of closing the coproc file descriptor
            coproc true

            kill -- -"$coproc_pid" "$coproc_pid" 2>/dev/null
            wait "$coproc_pid"
            printf '\n%s' "$?"


        ) \
        | sed -u -e "$sed_script" \
        | (

            command="$BUFFER"
            data=''
            last=''
            while IFS= read -r line; do
                data+="$last$line"$'\n'
                line=
                while IFS= read -t0.05 -r line; do
                    data+="$line"$'\n'
                    line=
                done
                last="$line"

                # flush partial data
                printf '%s\n' "code=partial; $(declare -p command); $(declare -p data)"
                line=
            done

            code="${last:-"$line"}"
            if [[ "$data" == '(eval):1: command not found: '* ]]; then
                code=127
            elif (( code == 141 )); then
                # sigpipe; probably bc we truncated it
                code=0
            fi

            code="${code:-0}"
            printf '%s\n' "$(declare -p code); $(declare -p command); $(declare -p data)"
        )
    done
)

live_preview.format_pane() {
    local pane_name="$1"
    local preview="$2"

    local this_height="${live_preview_vars[${pane_name}_height]}"
    preview="$(<<<"$preview" sed -n -e "1,$(( this_height-1 ))p" -e "$(( this_height ))i${live_preview_config[ellipsis]}")"

    if (( this_height != maxheight )); then
        output+=(
            "${esc}[$((LINES+100))B"    # go to bottom
            "${esc}[$(( maxheight - height ))A"  # go up to start
        )
    fi
    output+=(
        "${esc}[J" # clear
        "$preview" # print preview
        $'\n'
    )
    (( height += this_height ))
}

live_preview.render() {
    # pause render
    printf '\x1b[?2026h'

    local maxheight="$1"; shift

    # go to end of line
    if (( BUFFERLINES != 1 )); then
        local oldcursor="$CURSOR"
        CURSOR="${#BUFFER}"
    fi
    zle -R

    local esc=$'\x1b'
    local output=(
        # scroll up / reserve space
        "${(pl:$maxheight+1::\x0b:)}"
        "${esc}[$((maxheight+1))A"          # go back up to cli
        "${esc}7"                           # save cursor pos
        "${esc}[$LINES;$((LINES+100))r"     # make scroll region very small
        "${esc}8"                           # restore cursor
        $'\n'                               # go down one line
        "${esc}[J"                          # clear
    )
    # print the preview
    if (( $# )); then
        local height=0
        local i
        local active_panes=( ${=live_preview_vars[active_panes]} )
        for i in {1..$#}; do
            live_preview.format_pane "${active_panes[i]}" "${(P)i}"
        done
    fi

    output+=(
        "${esc}[0;$((LINES+100))r"          # restore scroll region
        "${esc}8"                           # restore cursor again
    )
    printf %s "${output[@]}"


    # go back
    if (( BUFFERLINES != 1 )); then
        CURSOR="$oldcursor"
        zle -R
    fi

    # unpause render
    printf '\x1b[?2026l'
}

live_preview._add_pane() {
    if [[ "${preview[-1]}" != '' ]]; then
        if [[ "${preview[-1][-1]}" != $'\n' ]]; then
            preview[-1]+=$'\n'
        fi
        preview[-1]+=$'\n'
    fi

    set -o localoptions -o prompt_subst

    local key="$1"
    preview+=( '' )
    if (( live_preview_config[show_main_border] )) || [[ "$key" != main ]]; then
        local command="${live_preview_vars[${key}_command]}"
        local code="${live_preview_vars[${key}_code]}"

        local ellipsis="${live_preview_config[ellipsis]}"
        local border="${live_preview_config[border]}"
        local colour="${live_preview_config[border_${key}_colour]}"
        local border_start="${live_preview_config[border_start]}"
        local border_end="${live_preview_config[border_end]}"
        local format="${live_preview_config[border_${key}_label]}"

        local text
        print -v text -P "${colour}${border_start}${format}%-0<<${border_end}"
        preview[-1]+="$text"$'\x1b[0m'
    fi

    # show an error msg if failed
    if (( code != 0 )); then
        print -v text -f "${live_preview_config[failed_message]}" "$code"
        preview[-1]+="$text"$'\x1b[0m\n'
    fi

    # show the output
    local text="${live_preview_vars[${key}_preview]}"
    if (( live_preview_vars[${key}_scroll] > 0 )); then
        text="$(<<<"$text" sed "1,${live_preview_vars[${key}_scroll]}d")"
    fi
    if (( live_preview_config[dim] )); then
        preview[-1]+=$'\x1b[2m'
    fi
    preview[-1]+="$text"
    live_preview_vars[active_panes]+=" ${key}"
}

live_preview.on_update() {
    emulate -LR zsh

    local fd="$1"
    local data=

    # wait for a line from the worker
    if ! IFS= read -t0 -u "$fd" -r data; then
        # no input; dead
        zle -F "$fd"

        # close the pty
        if (( ${live_preview_vars[running]} )); then
            zpty -d "$LIVE_PREVIEW_ID"
            live_preview_vars[running]=0
        fi
        return
    fi

    local lines=( "$data" )
    # read until the most recent
    while IFS= read -t0.01 -u "$fd" -r data; do
        lines+=( "$data" )
    done

    local command=
    local code=nochange
    while [[ "${#lines[@]}" > 0 && "$code" == nochange ]]; do
        eval "${lines[-1]}"
        lines[-1]=()
    done

    if [[ "$code" != nochange ]]; then
        if [[ "$data" != "${live_preview_vars[main_preview]}" ]]; then
            live_preview_vars[main_scroll]=0
            live_preview_vars[main_preview]="$data"
        fi

        live_preview_vars[main_code]="$code"
        live_preview_vars[main_command]="$command"
    fi

    live_preview.redraw
}

live_preview.redraw() {
    local data="${live_preview_vars[main_preview]}"
    local code="${live_preview_vars[main_code]}"
    local command="${live_preview_vars[main_command]}"
    local height
    live_preview.get_height height
    live_preview_vars[main_height]=0
    live_preview_vars[saved_height]=0
    live_preview_vars[success_height]=0

    # clear highlights
    region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )

    live_preview_vars[active_panes]=''
    local preview=()
    live_preview._add_pane main

    # if the command failed, then show the previous successful preview
    if [[ "$code" != 0 && "$code" != partial ]]; then
        if [[ -n "${live_preview_config[highlight_failed_command]}" ]]; then
            region_highlight+=( "0 $(( ${#BUFFER} + 1 )) ${live_preview_config[highlight_failed_command]} memo=live_preview" )
        fi

        if [[ "${live_preview_vars[success_preview]}" =~ [[:graph:]] && ( "${live_preview_config[show_last_success_if_saved]}" != 0 || ! ( "${live_preview_vars[saved_preview]}" =~ [[:graph]] ) ) ]]; then
            live_preview._add_pane success
            live_preview_vars[success_height]="$(( int(height / 3) ))"
        fi
    fi

    # show the saved preview if any
    if [[ "${live_preview_vars[saved_preview]}" =~ [[:graph:]] ]]; then
        live_preview._add_pane saved
        live_preview_vars[saved_height]="$(( int(height / 3) ))"
    fi

    if ! [[ "${preview[*]}" =~ [[:graph:]] ]]; then
        preview=()
        live_preview_vars[active_panes]=''
    else
        live_preview_vars[main_height]="$(( height - live_preview_vars[saved_height] - live_preview_vars[success_height] ))"
    fi

    live_preview.render "$height" "${preview[@]}"

    if (( code == 0 )); then
        if [[ "$data" != "${live_preview_vars[success_preview]}" ]]; then
            live_preview_vars[success_preview]="$data"
            live_preview_vars[success_scroll]=0
        fi
        live_preview_vars[success_command]="$command"
        live_preview_vars[success_code]="$code"
    fi
}

live_preview.get_pane_at_y() {
    local __y="$1"
    local __var="$2"

    local __height
    live_preview.get_height __height
    (( __y -= LINES - __height ))

    local __pane_names=( ${=live_preview_vars[active_panes]} )
    local __pane
    for __pane in "${__pane_names[@]}"; do
        (( __y -= live_preview_vars[${__pane}_height] ))
        if (( __y <= 0 )); then
            break
        fi
    done

    printf -v "$__var" %s "$__pane"
}

live_preview.scroll_pane() {
    local pane="$1"
    local amount="$2"
    local scroll="${live_preview_vars[${pane}_scroll]}"

    if (( amount > 0 )); then
        local height="${live_preview_vars[${pane}_height]}"
        local text="${live_preview_vars[${pane}_preview]}"
        # this is just a heuristic
        local max="$(( $(<<<"$text" fold -w "$COLUMNS" | wc -l) - height ))"

        if (( scroll + amount > max )); then
            return
        fi

    elif (( amount < 0 && scroll + amount < 0 )); then
        return
    fi

    (( scroll = scroll + amount ))

    if (( live_preview_vars[${pane}_scroll] != scroll )); then
        live_preview_vars[${pane}_scroll]="$scroll"
        live_preview.redraw
    fi
}

live_preview.refresh() {
    zpty -w "$LIVE_PREVIEW_ID" "$(declare -p LINES); $(declare -p BUFFER)"
}

live_preview.run() {
    if (( ! live_preview_vars[running] )); then
        # start
        live_preview_vars[running]=1
        zpty "$LIVE_PREVIEW_ID" live_preview.worker
        zle -Fw "$REPLY" live_preview.on_update

        if (( live_preview_config[enable_mouse] )); then
            zsh-enable-sgr-mouse 1
        fi

    fi
    live_preview.refresh
}

live_preview.update() {
    if (( live_preview_vars[active] )); then
        live_preview.run
    fi
}

live_preview.start() {
    if (( ! live_preview_vars[active] )); then
        live_preview_vars[active]=1
        zle reset-prompt
    fi
    live_preview.run
}

live_preview.stop() {
    if (( live_preview_vars[active] )); then
        live_preview_vars[active]=
        zle reset-prompt
    fi

    if (( live_preview_vars[running] )); then
        region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )
        zpty -d "$LIVE_PREVIEW_ID"
        live_preview_vars[running]=0

        if (( live_preview_config[enable_mouse] )); then
            zsh-enable-sgr-mouse 0
        fi
    fi
}

live_preview.reset() {
    live_preview.stop
    live_preview_vars=()
}

live_preview.toggle() {
    if (( ${live_preview_vars[running]} )); then
        live_preview.stop
    else
        live_preview.start
    fi
}

live_preview.save() {
    live_preview_vars[saved_preview]="${live_preview_vars[main_preview]}"
    live_preview_vars[saved_code]="${live_preview_vars[main_code]}"
    live_preview_vars[saved_command]="${live_preview_vars[main_command]}"
    live_preview_vars[saved_scroll]=0
}

live_preview.mouse_scroll() {
    emulate -LR zsh

    if (( live_preview_config[enable_mouse] )); then
        local pane
        live_preview.get_pane_at_y "$3" pane
        if [[ "$1" == scrolldown ]]; then
            live_preview.scroll_pane "$pane" "$(( live_preview_config[mouse_natural_scrolling] ? -1 : 1 ))"
        else
            live_preview.scroll_pane "$pane" "$(( live_preview_config[mouse_natural_scrolling] ? 1 : -1 ))"
        fi
    fi
}

zle -N live_preview.on_update
zle -N live_preview.reset
zle -N live_preview.update

# toggle real-time preview update on/off
zle -N live_preview.toggle
# turn real-time preview update on
zle -N live_preview.start
# turn real-time preview update off
zle -N live_preview.stop
# run/update the preview once (not real-time)
zle -N live_preview.run
# save the current output into the saved pane
zle -N live_preview.save

autoload -U add-zle-hook-widget
add-zle-hook-widget line-pre-redraw live_preview.update
add-zle-hook-widget line-finish live_preview.reset

if (( live_preview_config[enable_mouse] )); then
    bindmouse scrollup live_preview.mouse_scroll
    bindmouse scrolldown live_preview.mouse_scroll
fi
