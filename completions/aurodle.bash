# bash completion for aurodle

_aurodle() {
    local cur prev words cword
    _init_completion || return

    local commands="sync build clone info search show resolve buildorder outdated upgrade clean"
    local short_aliases="-S -Sw -Si -Ss -Qu -Su -Sc -Scc"
    local global_opts="-h --help -v --version -q --quiet"
    local build_opts="--noconfirm --noshow --needed --rebuild --asdeps --asexplicit --devel --chroot --ignore"
    local clone_opts="--recurse"
    local clean_opts="--all"
    local search_opts="--by --sort --rsort --raw"

    # Find the command (first non-option argument)
    local cmd=""
    local i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            sync|-S)       cmd=sync ;;
            build|-Sw)     cmd=build ;;
            clone)         cmd=clone ;;
            info|-Si)      cmd=info ;;
            search|-Ss)    cmd=search ;;
            show)          cmd=show ;;
            resolve)       cmd=resolve ;;
            buildorder)    cmd=buildorder ;;
            outdated|-Qu)  cmd=outdated ;;
            upgrade|-Su)   cmd=upgrade ;;
            clean|-Sc|-Scc) cmd=clean ;;
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
            COMPREPLY=($(compgen -W "name name-desc maintainer" -- "$cur"))
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
        COMPREPLY=($(compgen -W "$commands $short_aliases $global_opts" -- "$cur"))
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
            COMPREPLY=($(compgen -W "--devel --quiet" -- "$cur"))
            ;;
        upgrade)
            COMPREPLY=($(compgen -W "$build_opts" -- "$cur"))
            ;;
        clean)
            COMPREPLY=($(compgen -W "$clean_opts" -- "$cur"))
            ;;
        *)
            # info, show, resolve, buildorder: no extra options
            ;;
    esac
}

complete -F _aurodle aurodle
