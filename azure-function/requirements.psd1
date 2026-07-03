# requirements.psd1
# Managed dependencies, installed automatically by the runtime at startup.
#
# IMPORTANT: do NOT reference the full 'Microsoft.Graph' meta-module. It bundles
# ~40 submodules and regularly makes the dependency installer time out on cold
# start. Declare only the submodules the engine actually uses.
@{
    'Microsoft.Graph.Authentication'               = '2.*'
    'Microsoft.Graph.Users'                        = '2.*'
    'Microsoft.Graph.Users.Actions'                = '2.*'
    'Microsoft.Graph.Groups'                       = '2.*'
    'Microsoft.Graph.Identity.DirectoryManagement' = '2.*'
}
