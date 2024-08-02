# live preview

declare -A live_preview_config
live_preview_config[pty]="live_preview_pty_$RANDOM"
live_preview_config[debounce]=0.1
live_preview_config[timeout]=10
live_preview_config[height]=0.9
live_preview_config[char_limit]=100000
live_preview_config[highlight_failed_command]='bg=#330000'
live_preview_config[dim]=1
live_preview_config[sep]='━'
live_preview_config[label_start]='━━━━'
live_preview_config[label_end]=''
live_preview_config[failed_message]=$'\x1b[31mCommand failed with exit status %s\x1b[0m'
live_preview_config[preview_label]='%F{13}%B$label_start%S preview: $command %s'
live_preview_config[saved_label]='%F{3}%B$label_start%S saved: $command %s'
live_preview_config[success_label]='%F{2}%B$label_start%S last success: $command %s'

declare -A live_preview_vars=(
    [active]=
    [running]=

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

live_preview.get_height() {
    local __height="${live_preview_config[height]}"
    if (( __height < 1 )); then
        # calc preview height if fraction
        __height="$(( LINES * __height ))"
        __height="${__height%.*}"
    fi
    printf -v "$1" %i "$__height"
}

live_preview.worker() (
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
            printf 'partial=0; code=nochange; line=\n'
            continue
        fi
        prev="$BUFFER"

        # input is all whitespace
        # (it's probably just all blank though? since whitespace is stripped above)
        if [[ "$BUFFER" =~ ^\\s*$ ]]; then
            printf 'partial=0; code=0; line=\n'
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
            # use sed to truncate the lines
            timeout "${live_preview_config[timeout]}" cat <&p \
            | sed -u -n \
                -e "1,${height}p" \
                -e "$((height+1))i..." \
                -e "$((height+2))q"

            # this has the effect of closing the coproc file descriptor
            coproc true

            kill -- -"$coproc_pid" "$coproc_pid" 2>/dev/null
            wait "$coproc_pid"
            printf '\n%s' "$?"

        ) | (

            command="$BUFFER"
            data=()
            last=''
            while IFS= read -r line; do
                data+=( "$last$line" )
                line=
                while IFS= read -t0.05 -r line; do
                    data+=( "$line" )
                    line=
                done
                last="$line"

                # flush partial data
                line="${(F)data[@]}"
                line="${line::${live_preview_config[char_limit]}}"
                printf '%s\n' "partial=1; $(declare -p command); $(declare -p line)"
                line=
            done

            code="${last:-"$line"}"
            if [[ "$data" == '(eval):1: command not found: '* ]]; then
                code=127
            elif (( code == 141 )); then
                # sigpipe; probably bc we truncated it
                code=0
            fi

            line="${(F)data[@]}"
            line="${line::${live_preview_config[char_limit]}}"
            code="${code:-0}"
            printf '%s\n' "partial=0; $(declare -p command); $(declare -p code); $(declare -p line)"
        )
    done
)

live_preview.show_message() {
    # pause render
    printf '\x1b[?2026h'

    local minheight="$1" message="$2"
    # remove unhandled escapes
    if [[ "$message" =~ $'\x1b'[^[]] || "$message" =~ $'\x1b'\\[[?\>=!]?[0-9:\;]*[^0-9:\;m] ]]; then
        message="$(<<<"$message" sed 's/\x1b[ #%()*+].//; s/\x1b[^[]//g; s/\x1b\[[?>=!]?[0-9:;]*[^0-9:;m]//g')"
    fi

    # go to end of line
    if (( BUFFERLINES != 1 )); then
        local oldcursor="$CURSOR"
        CURSOR="${#BUFFER}"
    fi
    if (( minheight )); then
        if (( minheight > LINES-2 )); then
            minheight="$((LINES-2))"
        fi
        # use zle -M to reserve space
        local buffer
        print -vbuffer -f ' %.s\n' {1..$minheight}
        zle -M -- "$buffer"
    fi
    zle -R

    # save cursor pos
    # make scroll region very small
    # restore cursor
    # go down one line
    # print message
    # restore scroll region
    # restore cursor again
    printf '\x1b7\x1b[%i;%ir\x1b8\n\x1b[J%s\x1b[0;%ir\x1b8' "$LINES" "$((LINES+100))" "$message" "$((LINES+100))"
    # go back
    if (( BUFFERLINES != 1 )); then
        CURSOR="$oldcursor"
        zle -R
    fi

    # unpause render
    printf '\x1b[?2026l'
}

live_preview._add_pane() {
    if [[ "$preview" != '' ]]; then
        if [[ "${preview[-1]}" != $'\n' ]]; then
            preview+=$'\n'
        fi
        preview+=$'\n'
    fi

    set -o localoptions -o prompt_subst

    local format="$1"
    local key="$2"

    local command="${live_preview_vars[${key}_buffer]}"
    local code="${live_preview_vars[${key}_code]}"
    local line="${live_preview_vars[${key}_preview]}"
    local label_start="${live_preview_config[label_start]}"
    local text
    print -v text -P "${format}%-0<<${sep}${live_preview_config[label_end]}"
    preview+="$text"$'\x1b[0m'

    # show an error msg if failed
    if (( code != 0 )); then
        print -v text -f "${live_preview_config[failed_message]}" "$code"
        preview+="$text"$'\x1b[0m\n'
    fi

    # show the output
    preview+="$line"
}

live_preview.display() {
    local fd="$1"
    local partial=
    local line=
    local command=
    local code="${live_preview_vars[last_code]}"

    # wait for a line from the worker
    if ! IFS= read -t0 -u "$fd" -r line; then
        # no input; dead
        zle -F "$fd"

        # close the pty
        if (( ${live_preview_vars[running]} )); then
            zpty -d "${live_preview_config[pty]}"
            live_preview_vars[running]=0
        fi
        return
    fi

    # read until the most recent
    while IFS= read -t0.01 -u "$fd" -r line; do :; done

    eval "$line"

    if [[ "$code" == nochange ]]; then
        line="${live_preview_vars[last_preview]}"
        code="${live_preview_vars[last_code]}"
        command="${live_preview_vars[last_buffer]}"
    else
        live_preview_vars[last_preview]="$line"
        live_preview_vars[last_code]="$code"
        live_preview_vars[last_buffer]="$command"
    fi

    local sep="${live_preview_config[sep]}"
    sep="${(pl:$COLUMNS::$sep:)}"
    local preview=
    live_preview._add_pane "${live_preview_config[preview_label]}" last

    region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )

    # show the saved preview if any
    if [[ "${live_preview_vars[last_saved_preview]}" =~ [[:graph:]] ]]; then
        live_preview._add_pane "${live_preview_config[saved_label]}" last_saved
    fi

    # if the command failed, then show the previous successful preview
    if (( code != 0 )); then
        if [[ -n "${live_preview_config[highlight_failed_command]}" ]]; then
            region_highlight+=( "0 $(( ${#BUFFER} + 1 )) ${live_preview_config[highlight_failed_command]} memo=live_preview" )
        fi

        if [[ "${live_preview_vars[last_successful_preview]}" =~ [[:graph:]] ]]; then
            live_preview._add_pane "${live_preview_config[success_label]}" last_successful
        fi
    fi

    local height
    live_preview.get_height height
    preview="$(<<<"$preview" sed -n \
        -e "1,${height}p" \
        -e "$((height+1))i..." \
    )"

    if ! [[ "$preview" =~ [[:graph:]] ]]; then
        height=0
    fi

    if (( ${live_preview_config[dim]} )); then
        # make it all dim
        preview=$'\x1b[2m'"$(<<<"$preview" sed 's/\x1b\[[0-9:;]*/&;2/g')"
    fi
    live_preview.show_message "$height" "$preview"

    if (( !partial && code == 0 )); then
        live_preview_vars[last_successful_preview]="$line"
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

autoload -U add-zle-hook-widget
add-zle-hook-widget line-pre-redraw live_preview.update
add-zle-hook-widget line-finish live_preview.reset
