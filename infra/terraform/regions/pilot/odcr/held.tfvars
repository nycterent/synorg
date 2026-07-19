# synorg-e2e-cheap-overlay — written by tests/e2e/cheap-overlay/apply.sh; removed by its 'clean' mode
#
# e2e cheap-mode ODCR declaration: ONE held g4dn.xlarge. A held ODCR bills like
# a running instance from the moment it is created — keep the carve window
# short (runbooks/e2e-gpu-run.md, cheap mode). Apply is human-gated as always
# (deploy.sh never -auto-approves the ODCR module). Only use in a sandbox
# account with NO production reservations in state: prevent_destroy hard-errors
# otherwise, by design.
held_reservations = {
  g4dn-xlarge-a = {
    instance_type     = "g4dn.xlarge"
    availability_zone = "us-east-1a"
    instance_count    = 1
  }
}
