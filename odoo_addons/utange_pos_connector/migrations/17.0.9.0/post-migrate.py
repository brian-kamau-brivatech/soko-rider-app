def migrate(cr, version):
    """New right "Take payment": people who could sell before keep charging (only waiters get it switched off)."""
    for table in ('res_users', 'hr_employee'):
        cr.execute("SELECT 1 FROM information_schema.columns WHERE table_name = %s AND column_name = 'utange_perm_charge'", (table,))
        if cr.fetchone():
            cr.execute("UPDATE %s SET utange_perm_charge = utange_perm_sell WHERE utange_perm_charge IS NOT TRUE" % table)
