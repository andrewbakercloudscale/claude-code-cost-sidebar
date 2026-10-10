Set up the Claude Code Cost Sidebar on this Mac from
https://github.com/andrewbakercloudscale/claude-code-cost-sidebar

1. Read the README's Requirements and Install sections first.
2. Check that I have Claude Code 2.1.287 or later (claude --version), git, jq, Node.js and Python 3.
   If one is missing, tell me the command to install it and ask before running it.
3. Clone the repository to ~/claude-code-cost-sidebar (git pull --ff-only if it is already there)
   and run: bash ~/claude-code-cost-sidebar/claude-panel-setup.sh
4. Confirm the usage-panel mod is installed and that ~/.local/bin/ccusage-panel.sh exists.
5. Tell me what was installed and where, how to uninstall it, and that the sidebar opens
   in the next Claude Code session I start (/reload-plugins --force in this one).

Do not use sudo, and do not change anything outside what the setup script itself does.
If a step fails, stop and show me its output; do not work around it.
