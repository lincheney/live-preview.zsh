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
live_preview_config[show_top_border]=0
live_preview_config[show_last_successful_if_saved]=1

live_preview_config[border]='━'
live_preview_config[border_start]='${(pl:4::$border:)}'
live_preview_config[border_end]='${(pl:$COLUMNS::$border:)}'
live_preview_config[border_colour]='%F{13}%B'
live_preview_config[border_saved_colour]='%F{3}%B'
live_preview_config[border_successful_colour]='%F{2}%B'
live_preview_config[border_label]='%S preview: $command %s'
live_preview_config[border_saved_label]='%S saved: $command %s'
live_preview_config[border_successful_label]='%S last success: $command %s'

declare -A live_preview_vars=(
    [active]=
    [running]=
    [pid]="$$"

    [last_preview]=
    [last_code]=
    [last_buffer]=

    [last_successful_preview]=
    [last_successful_code]=
    [last_successful_buffer]=

    [last_saved_preview]=
    [last_saved_code]=
    [last_saved_buffer]=
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
    printf -v "$1" %i "$__height"
}

live_preview.worker() (
    emulate -LR zsh

    stty -onlcr -inlcr
    local prev=
    local old_buffer=
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

        ) | (

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

    # remove unhandled escapes
    if [[ "$preview" =~ $'\x1b'[^[]] || "$preview" =~ $'\x1b'\\[[?\>=!]?[0-9:\;]*[^0-9:\;m] ]]; then
        preview="$(<<<"$preview" sed 's/\x1b[ #%()*+].//; s/\x1b[^[]//g; s/\x1b\[[?>=!]?[0-9:;]*[^0-9:;m]//g')"
    fi
    # make it dim
    if (( live_preview_config[dim] )); then
        preview=$'\x1b[2m'"$(<<<"$preview" sed 's/\x1b\[[0-9:;]*/&;2/g')"
    fi
    local this_height="$(( int(maxheight * size / 3) ))"
    preview="$(<<<"$preview" sed -n -e "1,$(( this_height-1 ))p" -e "$(( this_height ))i...")"

    output+=(
        "${esc}[$((LINES+100))B"    # go to bottom
        "${esc}[$(( maxheight - height ))A"  # go up to start
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
        if (( maxheight > LINES-2 )); then
            maxheight="$((LINES-2))"
        fi
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
        "${esc}[J"      # clear
    )
    # print the preview
    local height=0
    if (( $# > 0 )); then
        live_preview.format_pane "${preview[1]}" "$(( 3 - $# + 1 ))"
    fi
    if (( $# > 1 )); then
        live_preview.format_pane "${preview[2]}" 1
    fi
    if (( $# > 2 )); then
        live_preview.format_pane "${preview[3]}" 1
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
    if (( live_preview_config[show_top_border] || ${#key} )); then
        local command="${live_preview_vars[last${key}_buffer]}"
        local code="${live_preview_vars[last${key}_code]}"

        local border="${live_preview_config[border]}"
        local colour="${live_preview_config[border${key}_colour]}"
        local border_start="${live_preview_config[border_start]}"
        local border_end="${live_preview_config[border_end]}"
        local format="${live_preview_config[border${key}_label]}"

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
    preview[-1]+="${live_preview_vars[last${key}_preview]}"
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

    if [[ "$code" == nochange ]]; then
        data="${live_preview_vars[last_preview]}"
        code="${live_preview_vars[last_code]}"
        command="${live_preview_vars[last_buffer]}"
    else
        live_preview_vars[last_preview]="$data"
        live_preview_vars[last_code]="$code"
        live_preview_vars[last_buffer]="$command"
    fi

    # clear highlights
    region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )

    local preview=()
    live_preview._add_pane ''

    # if the command failed, then show the previous successful preview
    if [[ "$code" != 0 && "$code" != partial ]]; then
        if [[ -n "${live_preview_config[highlight_failed_command]}" ]]; then
            region_highlight+=( "0 $(( ${#BUFFER} + 1 )) ${live_preview_config[highlight_failed_command]} memo=live_preview" )
        fi

        if [[ "${live_preview_config[show_last_successful_if_saved]}" != 0 && "$code" != 0 && "${live_preview_vars[last_successful_preview]}" =~ [[:graph:]] && "${live_preview_vars[last_successful_preview]}" != "${live_preview_vars[last_saved_preview]}" ]]; then
            live_preview._add_pane _successful
        fi
    fi

    # show the saved preview if any
    if [[ "${live_preview_vars[last_saved_preview]}" =~ [[:graph:]] ]]; then
        live_preview._add_pane _saved
    fi

    local height
    live_preview.get_height height
    if ! [[ "${preview[*]}" =~ [[:graph:]] ]]; then
        preview=()
    fi

    live_preview.show_message "$height" "${preview[@]}"

    if (( code == 0 )); then
        live_preview_vars[last_successful_preview]="$data"
        live_preview_vars[last_successful_buffer]="$command"
        live_preview_vars[last_successful_code]="$code"
    fi
}

live_preview.run() {
    if (( ! live_preview_vars[running] )); then
        # start
        live_preview_vars[running]=1
        zpty "${live_preview_config[pty]}" live_preview.worker
        zle -Fw "$REPLY" live_preview.display
    fi
    zpty -w "${live_preview_config[pty]}" "$(declare -p LINES); $(declare -p BUFFER)"
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

    if (( ${live_preview_vars[running]} )); then
        region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )
        zpty -d "${live_preview_config[pty]}"
        live_preview_vars[running]=0
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
    live_preview_vars[last_saved_preview]="${live_preview_vars[last_preview]}"
    live_preview_vars[last_saved_code]="${live_preview_vars[last_code]}"
    live_preview_vars[last_saved_buffer]="${live_preview_vars[last_buffer]}"
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
