# bash completion for aurodle

_aurodle() {
    local cur prev words cword
    _init_completion || return

    local commands="sync build clone info search show resolve buildorder outdated upgrade clean status"
    local global_opts="-h --help -V --version -q --quiet"
    local build_opts="--noconfirm --noshow --needed --rebuild --asdeps --asexplicit --chroot --ignore"
    local clone_opts="--recurse"
    local clean_opts="--all --noconfirm"
    local search_opts="--by --sort --rsort"

    # Find the command (first non-option argument)
    local cmd=""
    local i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            sync)          cmd=sync ;;
            build)         cmd=build ;;
            clone)         cmd=clone ;;
            info)          cmd=info ;;
            search)        cmd=search ;;
            show)          cmd=show ;;
            resolve)       cmd=resolve ;;
            buildorder)    cmd=buildorder ;;
            outdated)      cmd=outdated ;;
            upgrade)       cmd=upgrade ;;
            clean)         cmd=clean ;;
            status)        cmd=status ;;
            -*) ;;
            *)  break ;;
        esac
        if [[ -n "$cmd" ]]; then
            break
        fi
    done

    # Handle --flag value completions
    case "$prev" in
        --by)
            COMPREPLY=($(compgen -W "name name-desc depends makedepends checkdepends optdepends maintainer submitter provides conflicts replaces keywords groups comaintainers" -- "$cur"))
            return
            ;;
        --sort|--rsort)
            COMPREPLY=($(compgen -W "name votes popularity" -- "$cur"))
            return
            ;;
        --ignore)
            # No completion for package names (user-provided)
            return
            ;;
    esac

    # If no command yet, complete commands and global options
    if [[ -z "$cmd" ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi

    # Complete options based on command
    case "$cmd" in
        sync)
            COMPREPLY=($(compgen -W "$build_opts" -- "$cur"))
            ;;
        build)
            COMPREPLY=($(compgen -W "$build_opts" -- "$cur"))
            ;;
        clone)
            COMPREPLY=($(compgen -W "$clone_opts" -- "$cur"))
            ;;
        search)
            COMPREPLY=($(compgen -W "$search_opts" -- "$cur"))
            ;;
        outdated)
            COMPREPLY=($(compgen -W "--devel -q --quiet --all --ignore" -- "$cur"))
            ;;
        upgrade)
            COMPREPLY=($(compgen -W "$build_opts --devel --all" -- "$cur"))
            ;;
        clean)
            COMPREPLY=($(compgen -W "$clean_opts" -- "$cur"))
            ;;
        resolve)
            COMPREPLY=($(compgen -W "--chroot" -- "$cur"))
            ;;
        buildorder)
            COMPREPLY=($(compgen -W "--chroot -q --quiet" -- "$cur"))
            ;;
        *)
            # info, show: no extra options
            ;;
    esac
}

complete -F _aurodle aurodle
