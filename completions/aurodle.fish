# fish completion for aurodle

# Disable file completions by default
complete -c aurodle -f

# Helper: check if a subcommand has been given
function __aurodle_no_subcommand
    set -l cmd (commandline -opc)
    for c in $cmd[2..]
        switch $c
            case sync build clone info search show resolve buildorder outdated upgrade clean \
                 '-S' '-Sw' '-Si' '-Ss' '-Qu' '-Su' '-Sc' '-Scc'
                return 1
        end
    end
    return 0
end

function __aurodle_using_subcommand
    set -l cmd (commandline -opc)
    for c in $cmd[2..]
        switch $c
            case $argv
                return 0
        end
    end
    return 1
end

# Global options
complete -c aurodle -s h -l help -d 'Show help'
complete -c aurodle -s v -l version -d 'Show version'
complete -c aurodle -s q -l quiet -d 'Reduce output verbosity'

# Commands
complete -c aurodle -n __aurodle_no_subcommand -a sync -d 'Install AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a build -d 'Build packages into local repository'
complete -c aurodle -n __aurodle_no_subcommand -a clone -d 'Clone AUR package repositories'
complete -c aurodle -n __aurodle_no_subcommand -a info -d 'Display AUR package information'
complete -c aurodle -n __aurodle_no_subcommand -a search -d 'Search AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a show -d 'Display package build files'
complete -c aurodle -n __aurodle_no_subcommand -a resolve -d 'Show dependency tree'
complete -c aurodle -n __aurodle_no_subcommand -a buildorder -d 'Show build order'
complete -c aurodle -n __aurodle_no_subcommand -a outdated -d 'List outdated AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a upgrade -d 'Upgrade outdated AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a clean -d 'Remove stale cache files'

# Short aliases
complete -c aurodle -n __aurodle_no_subcommand -a '-S' -d 'Install AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a '-Sw' -d 'Build packages into local repository'
complete -c aurodle -n __aurodle_no_subcommand -a '-Si' -d 'Display AUR package information'
complete -c aurodle -n __aurodle_no_subcommand -a '-Ss' -d 'Search AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a '-Qu' -d 'List outdated AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a '-Su' -d 'Upgrade outdated AUR packages'
complete -c aurodle -n __aurodle_no_subcommand -a '-Sc' -d 'Remove stale cache files'
complete -c aurodle -n __aurodle_no_subcommand -a '-Scc' -d 'Remove all cache files'

# Build options (sync, build, upgrade)
for cmd in sync '-S' build '-Sw' upgrade '-Su'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l noconfirm -d 'Skip confirmation prompts'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l noshow -d 'Skip build file review'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l needed -d 'Skip up-to-date packages'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l rebuild -d 'Force rebuild'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l asdeps -d 'Install as dependency'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l asexplicit -d 'Install as explicitly installed'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l devel -d 'Check VCS packages for updates'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l chroot -d 'Build in a clean chroot'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l ignore -d 'Skip packages' -x
end

# Clone options
for cmd in clone
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l recurse -d 'Recursively clone AUR dependencies'
end

# Clean options
for cmd in clean '-Sc' '-Scc'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l all -d 'Remove all built packages'
end

# Outdated options
for cmd in outdated '-Qu'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l devel -d 'Check VCS packages for updates'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l quiet -d 'Reduce output verbosity'
end

# Search options
for cmd in search '-Ss'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l by -d 'Search by field' -xa 'name name-desc maintainer'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l sort -d 'Sort results' -xa 'name votes popularity'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l rsort -d 'Reverse sort' -xa 'name votes popularity'
    complete -c aurodle -n "__aurodle_using_subcommand $cmd" -l raw -d 'Output raw JSON'
end
