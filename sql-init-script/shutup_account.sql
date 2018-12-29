CREATE TABLE mutelist (
    account INTEGER PRIMARY KEY,
    start_time INTEGER,
    end_time INTEGER,
    reason varchar(256),
    admin_account INTEGER
);

-- optimize the account lookups using index for mutelist
CREATE INDEX account_mutes ON mutelist (account);

CREATE TABLE gaglist (
    account INTEGER PRIMARY KEY,
    start_time INTEGER,
    end_time INTEGER,
    reason varchar(256),
    admin_account INTEGER
);

-- optimize the account lookups using index for gaglist
CREATE INDEX account_gags ON gaglist (account);