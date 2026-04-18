#compdef aurodle

# zsh completion for aurodle

_aurodle_search_fields() {
    local fields=(
        'name:Search by package name'
        'name-desc:Search by name and description'
        'maintainer:Search by maintainer'
    )
    _describe 'search field' fields
}

_aurodle_sort_fields() {
    local fields=(
        'name:Sort by package name'
        'votes:Sort by vote count'
        'popularity:Sort by popularity'
    )
    _describe 'sort field' fields
}

_aurodle_build_options() {
    _arguments -s \
        '--noconfirm[Skip confirmation prompts]' \
        '--noshow[Skip build file review]' \
        '--needed[Skip up-to-date packages]' \
        '--rebuild[Force rebuild]' \
        '--asdeps[Install as dependency]' \
        '--asexplicit[Install as explicitly installed]' \
        '--devel[Check VCS packages for updates]' \
        '--chroot[Build in a clean chroot]' \
        '--ignore[Skip packages]:packages:' \
        '*:package:'
}

_aurodle() {
    local -a commands=(
        'sync:Install AUR packages (resolve, clone, build, install)'
        'build:Build packages into local repository'
        'clone:Clone AUR package repositories'
        'info:Display AUR package information'
        'search:Search AUR packages'
        'show:Display package build files'
        'resolve:Show dependency tree'
        'buildorder:Show build order (machine-readable)'
        'outdated:List outdated AUR packages'
        'upgrade:Upgrade outdated AUR packages'
        'clean:Remove stale or all cache files'
    )

    local -a short_commands=(
        '-S:Install AUR packages'
        '-Sw:Build packages into local repository'
        '-Si:Display AUR package information'
        '-Ss:Search AUR packages'
        '-Qu:List outdated AUR packages'
        '-Su:Upgrade outdated AUR packages'
        '-Sc:Remove stale cache files'
        '-Scc:Remove all cache files'
    )

    local -a global_options=(
        '(-h --help)'{-h,--help}'[Show help]'
        '(-v --version)'{-v,--version}'[Show version]'
        '(-q --quiet)'{-q,--quiet}'[Reduce output verbosity]'
    )

    # If we haven't completed the subcommand yet
    if (( CURRENT == 2 )); then
        _describe 'command' commands
        _describe 'short command' short_commands
        _arguments -s $global_options
        return
    fi

    # Determine the subcommand
    local cmd="${words[2]}"
    case "$cmd" in
        sync|-S)
            _aurodle_build_options
            ;;
        build|-Sw)
            _aurodle_build_options
            ;;
        clone)
            _arguments -s \
                '--recurse[Recursively clone AUR dependencies]' \
                '*:package:'
            ;;
        info|-Si)
            _arguments '*:package:'
            ;;
        search|-Ss)
            _arguments -s \
                '--by[Search by field]:field:_aurodle_search_fields' \
                '--sort[Sort results]:field:_aurodle_sort_fields' \
                '--rsort[Reverse sort results]:field:_aurodle_sort_fields' \
                '--raw[Output raw JSON]' \
                '*:query:'
            ;;
        show)
            _arguments '*:package:'
            ;;
        resolve)
            _arguments '*:package:'
            ;;
        buildorder)
            _arguments '*:package:'
            ;;
        outdated|-Qu)
            _arguments -s \
                '--devel[Check VCS packages for updates]' \
                '(-q --quiet)'--quiet'[Reduce output verbosity]'
            ;;
        upgrade|-Su)
            _aurodle_build_options
            ;;
        clean|-Sc|-Scc)
            _arguments -s \
                '--all[Remove all built packages]'
            ;;
    esac
}

_aurodle "$@"
