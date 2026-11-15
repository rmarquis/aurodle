#compdef pacsaur

# zsh completion for pacsaur

# pacsaur takes pacman's command line: complete it with pacman's
# completion, and add pacsaur's own options.
_pacsaur() {
    local ret=1

    case ${words[CURRENT-1]} in
        --by)
            compadd name name-desc depends makedepends checkdepends optdepends \
                maintainer submitter provides conflicts replaces keywords groups comaintainers
            return
            ;;
        --sort|--rsort)
            compadd name votes popularity
            return
            ;;
    esac

    if [[ $PREFIX == --* ]]; then
        local -a own=(
            '--dry-run:Show what would run, without running it'
            '--repo:Send the whole command to pacman'
            '--aur:Send the whole command to the AUR side'
            '--noshow:Skip build file review'
            '--rebuild:Force rebuild'
            '--chroot:Build in a clean chroot'
            '--devel:Check VCS packages for updates'
            '--all:Also check uninstalled local repository packages'
            '--by:Search the AUR by field'
            '--sort:Sort AUR search results'
            '--rsort:Reverse sort AUR search results'
        )
        _describe 'pacsaur option' own && ret=0
    fi

    if (( $+functions[_pacman] )) || autoload -Uz +X _pacman 2>/dev/null; then
        local service=pacman
        _pacman "$@" && ret=0
    fi
    return ret
}

_pacsaur "$@"
