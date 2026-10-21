# Prior Art Research: Existing AUR Helpers

Research on the AUR helpers that inspired Aurodle's design, and the concepts adopted from each.

## Primary Inspirations

The following three tools pioneered key architectural concepts that have since
been adopted by various AUR helpers.

**Auracle** - Build Order & Architecture

- Modular command structure with specialized operations
- Topological dependency sorting for build order visualization
- Provider-based dependency matching through AUR search
- Non-building philosophy focusing on AUR interaction

**Aurutils** - Local Repository Management

- Uses custom pacman repositories instead of foreign packages
- Modular script collection with task separation
- Native pacman database integration and repository synchronization
- Git-based repository management with ninja build system

**Pacaur** - Minimal Interaction

- Designed for fast workflows with minimal user prompts
- Comprehensive non-interactive modes (--noconfirm, --noedit, --silent)
- Automated sudo management with timeout prevention
- Speed-focused design for repetitive tasks and automation

## Design Synthesis

**Adopted Concepts**:

- Topological dependency sorting with improved versioned dependency support
- Local repository architecture for native pacman integration
- Comprehensive non-interactive modes with intelligent defaults
- Clear build order visualization before execution
- Modular architecture with specialized commands

**Improvements Over Existing Tools**:

- Unified tool (no multiple script learning curve)
- Automated repository setup and management
- Robust error handling with clear messages
- Full versioned dependency resolution
- Consistent exit codes and status reporting
- Modern memory-safe implementation in Zig
