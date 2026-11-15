# fish completion for pacsaur

# pacsaur takes pacman's command line: complete it with pacman's
# completion, and add pacsaur's own options.
complete -c pacsaur --wraps pacman

complete -c pacsaur -l dry-run -d 'Show what would run, without running it'
complete -c pacsaur -l repo -d 'Send the whole command to pacman'
complete -c pacsaur -l aur -d 'Send the whole command to the AUR side'
complete -c pacsaur -l noshow -d 'Skip build file review'
complete -c pacsaur -l rebuild -d 'Force rebuild'
complete -c pacsaur -l chroot -d 'Build in a clean chroot'
complete -c pacsaur -l devel -d 'Check VCS packages for updates'
complete -c pacsaur -l all -d 'Also check uninstalled local repository packages'
complete -c pacsaur -l by -d 'Search the AUR by field' -xa 'name name-desc depends makedepends checkdepends optdepends maintainer submitter provides conflicts replaces keywords groups comaintainers'
complete -c pacsaur -l sort -d 'Sort AUR search results' -xa 'name votes popularity'
complete -c pacsaur -l rsort -d 'Reverse sort AUR search results' -xa 'name votes popularity'
