# live-preview.zsh

See a live preview of the output of your command as you type in ZSH.

This is a *very* helpful when you are writing data/text-processing shell pipelines
(e.g. with assorted `grep`, `cut`, `awk` etc)
to be able to see what your current command would do and iterate on it live,
*without* having to go through the cycle of
press enter, press up, edit the text, repeat;
instead just type until the preview looks right.

> I am supporting this code only in a limited fashion / insofar as I need.
> If you encounter issues, I expect you to do the troubleshooting yourself.

Note that the live preview is [potentially dangerous](#dangerous-commands).

### Demo

https://github.com/user-attachments/assets/48e16148-c254-4502-bf2b-6f6b4ee26274

## Usage

1. Clone/download the [live-preview.zsh](./live-preview.zsh) script and then `source` it (probably in your `~/.zshrc`).
1. Add a keybind to enable it (again probably in your `~/.zshrc`).
    * for example press `alt+p` to toggle it on/off: `bindkey '\ep' live_preview.toggle`
1. Then press your keybind and start typing.

You may be shown up to 3 preview panes:
* the so called "main" pane. This is simply the output of your current command.
* if your current command fails (non-zero exit code),
    you will also be shown a pane with the output of the last successful command.
* if you have [saved any outputs](#saved-pane), this will also show up as a pane.

### Configuration

There are a few of configuration options available.
You can modify them by modifying the `live_preview_config` associative array *after* you have sourced `live-preview.zsh`.
Refer to [the actual script](./live-preview.zsh) for what you can configure (they're all at the top of the script).

For example, to change the height of the preview to 20 lines: `live_preview_config[height]=20`.

### One shot preview

Sometimes you don't actually want the preview to run "as-you-type",
but you want to be able to trigger it only on a specific key.
In this case, don't make a keybinding for `live_preview.toggle`, instead make a keybinding for `live_preview.run`.

For example `bindkey '\ep' live_preview.run`

### Prompt indicator

The variable `${live_preview_vars[active]}` indicates if the preview is live.
You can use this in your prompt if you have `setopt PROMPT_SUBST`, e.g.
`PROMPT+='${live_preview_vars[active]:+"%F{10}%B (live)%f%b"} '`
will show `(live) ` in your prompt in bold light green.


### Saved pane

Sometimes, you want to be able to refer back to some previous output.

You can make a keybind e.g. for `alt+s`: `bindkey '\es' live_preview.save`.
This will "save" the output of the current command which will be shown in an additional pane.

For example, you are in the middle of typing `curl -s 'https://wttr.in/?format=j1' | jq somethingsomething`
but you want to be able to refer back to the original output of the `curl` command
while you are assembling your `jq` command.

### Dimming

The preview colours are dimmed by default using `\x1b[2m`.
If this does not look good in your terminal, you can turn it off: `live_preview_config[dim]=0`.

### Scrolling

If the preview does not fit on the screen, you may want to scroll it.
This can be done with `live_preview.scroll_pane PANE DELTA`,
where `PANE` is one of `main`, `saved` or `success`,
and `DELTA` is the scroll amount (negative numbers scroll up).

#### Mouse scrolling

There is basic mouse scrolling support.

You *must* have <https://github.com/lincheney/mouse.zsh> and `source` it *before* `live-preview.zsh`.

Then run 
```zsh
live_preview_config[enable_mouse]=1
live_preview.enable_mouse
```

### Caching

If you command makes network calls or is otherwise slow, this can make the live preview slow or laggy.
You may wish to *cache* the output of these commands.

`live-preview.zsh` has no builtin support for caching,
but you can use something like <https://github.com/dimo414/bkt> to do the caching for you.

A good cache key to use is `"$LIVE_PREVIEW_ID.$LINENO"`.

Here is what I do with [bkt](https://github.com/dimo414/bkt):
```zsh
live_preview.cache() {
    if (( live_preview_vars[running] )) && command -v bkt &>/dev/null; then
        set -- bkt --scope="$LIVE_PREVIEW_ID.$LINENO" -- "$@"
    fi
    "$@"
}

alias aws='live_preview.cache aws'
alias curl='live_preview.cache curl'
# add any other commands/aliases you want
```

### Running your command

There are no special tricks to running your command; just press `enter` as you normally do.

*However*, with the preview enabled, it can be tempting to *not* press `enter`
and just eyeball the preview instead.

If you are *finished/satisfied*, you *should* press `enter` to actually run your command,
even if all the info you wanted is already being shown in the preview.

By pressing `enter` and actually running your command,
the output will be printed "normally" to the terminal
so you can scroll up and look at it later if needed (previews on the other hand may be cleared)
*and* your command will be entered into the ZSH history if you wanted to run it again.


### Dangerous commands

The live preview **will** run the command (or even partial command) you have typed.
There is no sandboxing or "read-only-mode" or sanitisation or anything like that.
If the command (or partial command) is potentially dangerous or destructive, the live preview *will not stop it*.

If this worries you then try:
* be more careful about what you are typing.
    Use `echo`, comment symbols `#` or any dry run flags to neuter the effects of your dangerous commands.
    (I do this sometimes anyway even when not using the preview in case I accidentally brush the `enter` key).
* toggle the live preview off when you don't need/want it.
* increase the input debounce e.g. `live_preview_config[debounce]=0.5`.
    The preview does not actually update on every keystroke, only if the typed command has not changed after the debounce interval.
    Increase the debounce interval if you type slowly or want the preview to update less often
    (this also has the effect of making the preview lag more).
* don't run the preview "live".
    [Update the preview on a keybind instead](#one-shot-preview).
    Then you can press that keybind and update the preview only when you feel safe.
* just don't use it. Nobody is forcing you.


## Related/similar projects

* https://github.com/akavel/up
