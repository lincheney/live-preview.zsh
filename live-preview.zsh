# live preview

declare -A live_preview_config
live_preview_config[pty]="live_preview_pty_$RANDOM"
live_preview_config[debounce]=0.1
live_preview_config[timeout]=10
live_preview_config[height]=0.9
live_preview_config[char_limit]=100000
live_preview_config[highlight_failed_command]='bg=#330000'
live_preview_config[dim]=1
live_preview_config[failed_message]=$'\x1b[31mCommand failed with exit status %s\x1b[0m'
live_preview_config[show_main_border]=0
live_preview_config[show_last_success_if_saved]=1
live_preview_config[ellipsis]='…'

live_preview_config[border]='━'
live_preview_config[border_start]='${(pl:4::$border:)}'
live_preview_config[border_end]='${(pl:$COLUMNS::$border:)}'
live_preview_config[border_main_colour]='%F{13}%B'
live_preview_config[border_saved_colour]='%F{3}%B'
live_preview_config[border_success_colour]='%F{2}%B'
live_preview_config[border_main_label]='%S preview: %-5<$ellipsis<$command<< %s'
live_preview_config[border_saved_label]='%S saved: %-5<$ellipsis<$command%<< %s'
live_preview_config[border_success_label]='%S last success: %-5<$ellipsis<$command%<< %s'

declare -A live_preview_vars=(
    [active]=
    [running]=
    [pid]="$$"
    [cache]=

    [pane_names]=
    [pane_pos]=

    [main_preview]=
    [main_code]=
    [main_command]=
    [main_scroll]=

    [success_preview]=
    [success_code]=
    [success_command]=
    [success_scroll]=

    [saved_preview]=
    [saved_code]=
    [saved_command]=
    [saved_scroll]=
)

zmodload zsh/datetime
zmodload zsh/zpty
zmodload zsh/mathfunc

live_preview.get_height() {
    local __height="${live_preview_config[height]}"
    if (( __height < 1 )); then
        # calc preview height if fraction
        __height="$(( int(LINES * __height) ))"
    fi
    if (( __height && __height > LINES-2 )); then
        __height="$((LINES-2))"
    fi
    printf -v "$1" %i "$__height"
}

live_preview.worker() (
    emulate -LR zsh

    stty -onlcr -inlcr
    local prev=
    local old_buffer=

    # remove unhandled escapes
    local sed_script='s/\x1b[ #%()*+].//; s/\x1b[^[]//g; s/\x1b\[[?>=!]?[0-9:;]*[^0-9:;m]//g'
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
    local preview="$1"
    local size="$2"

    local this_height="$(( size == 3 ? maxheight : int(maxheight / 3) * size ))"
    preview="$(<<<"$preview" sed -n -e "1,$(( this_height-1 ))p" -e "$(( this_height ))i${live_preview_config[ellipsis]}")"

    if (( size != 3 )); then
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

live_preview.show_message() {
    # pause render
    printf '\x1b[?2026h'

    local maxheight="$1"; shift

    # go to end of line
    if (( BUFFERLINES != 1 )); then
        local oldcursor="$CURSOR"
        CURSOR="${#BUFFER}"
    fi
    if (( maxheight )); then
        # use zle -M to reserve space
        zle -M -- "${(pl:$maxheight::\n:)}"
    fi
    zle -R

    local esc=$'\x1b'
    local output=(
        "${esc}7"       # save cursor pos
        "${esc}[$LINES;$((LINES+100))r"     # make scroll region very small
        "${esc}8"       # restore cursor
        $'\n'           # go down one line
        "${esc}[J" # clear
    )
    live_preview_vars[pane_pos]=''
    # print the preview
    local height=0
    live_preview_vars[pane_pos]+="$(( LINES - maxheight ))"
    if (( $# > 0 )); then
        live_preview.format_pane "${preview[1]}" "$(( 3 - $# + 1 ))"
        live_preview_vars[pane_pos]+=" $(( LINES - maxheight + height ))"
    fi
    if (( $# > 1 )); then
        live_preview.format_pane "${preview[2]}" 1
        live_preview_vars[pane_pos]+=" $(( LINES - maxheight + height ))"
    fi
    if (( $# > 2 )); then
        live_preview.format_pane "${preview[3]}" 1
        live_preview_vars[pane_pos]+=" $(( LINES - maxheight + height ))"
    fi

    output+=(
        "${esc}[0;$((LINES+100))r"          # restore scroll region
        "${esc}8"       # restore cursor again
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
    if (( live_preview_config[show_top_border] )) || [[ "$key" != main ]]; then
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
    live_preview_vars[pane_names]+=" ${key}"
}

live_preview.display() {
    emulate -LR zsh

    local fd="$1"
    local data=

    # wait for a line from the worker
    if ! IFS= read -t0 -u "$fd" -r data; then
        # no input; dead
        zle -F "$fd"

        # close the pty
        if (( ${live_preview_vars[running]} )); then
            zpty -d "${live_preview_config[pty]}"
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

    # clear highlights
    region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )

    live_preview_vars[pane_names]=''
    local preview=()
    live_preview._add_pane main

    # if the command failed, then show the previous successful preview
    if [[ "$code" != 0 && "$code" != partial ]]; then
        if [[ -n "${live_preview_config[highlight_failed_command]}" ]]; then
            region_highlight+=( "0 $(( ${#BUFFER} + 1 )) ${live_preview_config[highlight_failed_command]} memo=live_preview" )
        fi

        if [[ "${live_preview_config[show_last_success_if_saved]}" != 0 && "$code" != 0 && "${live_preview_vars[success_preview]}" =~ [[:graph:]] && "${live_preview_vars[success_preview]}" != "${live_preview_vars[saved_preview]}" ]]; then
            live_preview._add_pane success
        fi
    fi

    # show the saved preview if any
    if [[ "${live_preview_vars[saved_preview]}" =~ [[:graph:]] ]]; then
        live_preview._add_pane saved
    fi

    local height
    live_preview.get_height height
    if ! [[ "${preview[*]}" =~ [[:graph:]] ]]; then
        preview=()
    fi

    live_preview.show_message "$height" "${preview[@]}"

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
    local y="$1"
    local var="$2"

    local pane_pos=( ${=live_preview_vars[pane_pos]} )
    local i
    for (( i = 2 ; i < ${#pane_pos[@]} && pane_pos[i] < y; i++ )); do :; done

    local pane_names=( ${=live_preview_vars[pane_names]} )
    printf -v "$var" %s "${pane_names[$i-1]}"
}

live_preview.scroll_pane() {
    local pane="$1"
    local amount="$2"
    local scroll="${live_preview_vars[${pane}_scroll]}"

    if (( amount > 0 )); then
        local pane_pos=( ${=live_preview_vars[pane_pos]} )
        local pane_names=( ${=live_preview_vars[pane_names]} )
        local i="${pane_names[(ie)$pane]}"
        local height="$(( pane_pos[i+1] - pane_pos[i] ))"
        local max="$(( $(wc -l <<<"${live_preview_vars[${pane}_preview]}") - height ))"

        if (( scroll + amount > max )); then
            return
        fi

    elif (( amount < 0 && scroll + amount < 0 )); then
        return
    fi

    (( scroll = scroll + amount ))

    if (( live_preview_vars[${pane}_scroll] != scroll )); then
        live_preview_vars[${pane}_scroll]="$scroll"
        live_preview.refresh
    fi
}

live_preview.refresh() {
    zpty -w "${live_preview_config[pty]}" "$(declare -p LINES); $(declare -p BUFFER)"
}

live_preview.run() {
    if (( ! live_preview_vars[running] )); then
        # start
        live_preview_vars[running]=1
        zpty "${live_preview_config[pty]}" live_preview.worker
        zle -Fw "$REPLY" live_preview.display

        if (( live_preview_config[enable_mouse] )); then
            zsh-enable-mouse 1
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
        zpty -d "${live_preview_config[pty]}"
        live_preview_vars[running]=0

        if (( live_preview_config[enable_mouse] )); then
            zsh-enable-mouse 0
        fi
    fi
}

live_preview.reset() {
    live_preview.stop
    live_preview_vars=( [pid]="$$" )
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

zle -N live_preview.display
zle -N live_preview.toggle
zle -N live_preview.reset
zle -N live_preview.start
zle -N live_preview.stop
zle -N live_preview.update
zle -N live_preview.run
zle -N live_preview.save

autoload -U add-zle-hook-widget
add-zle-hook-widget line-pre-redraw live_preview.update
add-zle-hook-widget line-finish live_preview.reset
