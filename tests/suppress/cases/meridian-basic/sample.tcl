# Sample set_rule_status input for the importer. The command
# shape mirrors observed commercial waiver files; every rule
# name, glob, and comment below is invented for the suite.
set_rule_status -rule {W_MASYNC} -status {Waived} \
  -expression {(Driver =~ "u_top.u_a.*") && (ReceivingFlop =~ "u_top.u_b.sync0")} \
  -comment {async path reviewed with the designer}
set_rule_status -rule {W_UNMAPPED_DEMO} -status {Waived} \
  -expression {(Driver =~ "u_top.u_c.*")} \
  -comment {no icarium mapping exists yet}
set_rule_status -rule {W_MASYNC} -status {Review} \
  -expression {(Driver =~ "u_top.u_d.*")} \
  -comment {still under review, excuses nothing}
