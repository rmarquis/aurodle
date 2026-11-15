# bash completion for pacsaur

# pacsaur takes pacman's command line: complete it with pacman's
# completion, and add pacsaur's own options.
_pacsaur() {
    local cur prev words cword
    _init_completion || return

    case "$prev" in
        --by)
            COMPREPLY=($(compgen -W "name name-desc depends makedepends checkdepends optdepends maintainer submitter provides conflicts replaces keywords groups comaintainers" -- "$cur"))
            return
            ;;
        --sort|--rsort)
            COMPREPLY=($(compgen -W "name votes popularity" -- "$cur"))
            return
            ;;
    esac

    if ! declare -F _pacman >/dev/null; then
        _comp_load pacman 2>/dev/null || _completion_loader pacman 2>/dev/null
    fi
    if declare -F _pacman >/dev/null; then
        _pacman
    fi

    if [[ $cur == --* ]]; then
        local own="--dry-run --repo --aur --noshow --rebuild --chroot --devel --all --by --sort --rsort"
        COMPREPLY+=($(compgen -W "$own" -- "$cur"))
    fi
}

complete -F _pacsaur pacsaur
