# live preview

declare -A live_preview_config
live_preview_config[debounce]=0.1
live_preview_config[timeout]=10
live_preview_config[height]=0.9
live_preview_config[char_limit]=100000

declare -A live_preview_vars=(
    [pty]="live_preview_pty_$RANDOM"
    [active]=0
    [running]=0
    [last_code]=
    [last_preview]=
    [last_successful_preview]=
    [last_saved_preview]=
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
    local height=
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
                printf '%s\n' "partial=1; $(declare -p line)"
                line=
            done

            if [[ "${#data[@]}" > 0 && "${data[-1]}" == '' ]]; then
                # drop trailing blank line
                data=( "${data[@]:0: -1}" )
            fi

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
            printf '%s\n' "partial=0; $(declare -p code); $(declare -p line)"
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
    # print message + newline
    # restore scroll region
    # restore cursor again
    printf '\x1b7\x1b[%i;%ir\x1b8\n\x1b[J%s\n\x1b[0;%ir\x1b8' "$LINES" "$((LINES+100))" "$message" "$((LINES+100))"
    # go back
    if (( BUFFERLINES != 1 )); then
        CURSOR="$oldcursor"
        zle -R
    fi

    # unpause render
    printf '\x1b[?2026l'
}

live_preview.display() {
    local fd="$1"
    local partial=
    local line=
    local code="${live_preview_vars[last_code]}"

    # wait for a line from the worker
    if ! IFS= read -t0 -u "$fd" -r line; then
        # no input; dead
        zle -F "$fd"

        # close the pty
        if (( ${live_preview_vars[running]} )); then
            zpty -d "${live_preview_vars[pty]}"
            live_preview_vars[running]=0
        fi
        return
    fi

    # read until the most recent
    while IFS= read -t0 -u "$fd" -r line; do :; done

    eval "$line"

    if [[ "$line" == '(eval):1: parse error near '* ]]; then
        :

    elif [[ -n "$BUFFER" ]]; then

        if [[ "$line" != "${live_preview_vars[last_preview]}" || "$code" != "${live_preview_vars[last_code]}" ]]; then
            region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )

            local height
            live_preview.get_height height

            local sep=
            print -v sep -f '─%.s' {1..$COLUMNS}

            local preview="$line"

            # show the saved preview
            if [[ "${live_preview_vars[last_saved_preview]}" =~ [[:graph:]] ]]; then
                if [[ "${preview[-1]}" != $'\n' ]]; then
                    preview+=$'\n'
                fi
                preview+=$'\x1b[31m\n'"$sep"$'\x1b[0m\n'"${live_preview_vars[last_saved_preview]}"
            fi

            # if the command failed, then output an error message and show the previous successful preview
            if (( code != 0 )); then
                region_highlight+=( "0 $(( ${#BUFFER} + 1 )) bg=#330000 memo=live_preview" )
                preview=$'\x1b[31m'"Command failed with exit status $code"$'\x1b[0m\n'"$preview"

                if [[ "${live_preview_vars[last_successful_preview]}" =~ [[:graph:]] ]]; then
                    if [[ "${preview[-1]}" != $'\n' ]]; then
                        preview+=$'\n'
                    fi
                    preview+=$'\x1b[31m\n'"$sep"$'\x1b[0m\n'"${live_preview_vars[last_successful_preview]}"
                fi
            fi

            preview="$(<<<"$preview" sed -n \
                -e "1,${height}p" \
                -e "$((height+1))i..." \
            )"
            if ! [[ "$preview" =~ [[:graph:]] ]]; then
                height=0
            fi

            # make it all dim
            preview=$'\x1b[2m'"$(<<<"$preview" sed 's/\x1b\[[0-9:;]*/&;2/g')"
            live_preview.show_message "$height" "$preview"
        fi

    elif [[ -n "${live_preview_vars[last_preview]}" ]]; then
        zle -M ''
        line=
    fi

    live_preview_vars[last_preview]="$line"
    live_preview_vars[last_code]="$code"
    if (( !partial && code == 0 )); then
        live_preview_vars[last_successful_preview]="$line"
    fi
}

live_preview.run() {
    if (( ! ${live_preview_vars[running]} )); then
        # start
        live_preview_vars[running]=1
        zpty "${live_preview_vars[pty]}" live_preview.worker
        zle -Fw "$REPLY" live_preview.display
    fi
    zpty -w "${live_preview_vars[pty]}" "LINES=${(q)LINES}; BUFFER=${(q)BUFFER}"
}

live_preview.update() {
    if (( ${live_preview_vars[active]} )); then
        live_preview.run
    fi
}

live_preview.start() {
    live_preview_vars[active]=1
    live_preview.run
}

live_preview.stop() {
    live_preview_vars[active]=0

    if (( ${live_preview_vars[running]} )); then
        region_highlight=( "${region_highlight[@]:#*memo=live_preview}" )
        zpty -d "${live_preview_vars[pty]}"
        live_preview_vars[running]=0
    fi
}

live_preview.reset() {
    live_preview.stop
    live_preview_vars[last_preview]=
    live_preview_vars[last_successful_preview]=
    live_preview_vars[last_saved_preview]=
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
