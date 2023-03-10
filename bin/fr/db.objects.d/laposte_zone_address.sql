/***
 * FR: add LAPOSTE/RAN ZA
 */

-- address-ZA with history (date & type of last change)
CREATE TABLE IF NOT EXISTS fr.laposte_zone_address
(
    co_cea CHAR(10) NOT NULL
    , dt_reference DATE NOT NULL
    , co_mouvement CHAR(1) NOT NULL
    , fl_active BOOLEAN NOT NULL
    , co_postal CHARACTER VARYING(5) NOT NULL
    , co_insee_commune CHAR(5) NOT NULL
    , co_insee_commune_precedente CHAR(5)
    , lb_in_ext_loc CHARACTER VARYING(72) NOT NULL
    , lb_nn CHARACTER VARYING(38) NOT NULL
    , lb_l5_nn CHARACTER VARYING(38) NULL
    , lb_ach_nn CHARACTER VARYING(38) NOT NULL
    , dt_reference_commune DATE NOT NULL
    , co_insee_commune_ran CHAR(5) NOT NULL
    , co_insee_commune_precedente_ran CHAR(5)
    , co_insee_departement VARCHAR(3) NOT NULL
);

-- manual VACUUM
ALTER TABLE fr.laposte_zone_address SET (
    AUTOVACUUM_ENABLED = FALSE
);

SELECT drop_all_functions_if_exists('fr', 'setLaPosteIndexZoneAddress');
CREATE OR REPLACE PROCEDURE fr.setLaPosteIndexZoneAddress()
AS
$proc$
BEGIN
    -- uniq CEA
    IF index_exists('fr', 'idx_za_co_cea') AND NOT index_exists('fr', 'iux_laposte_zone_address_co_cea') THEN
        ALTER INDEX idx_za_co_cea RENAME TO iux_laposte_zone_address_co_cea;
    ELSE
        CREATE UNIQUE INDEX IF NOT EXISTS iux_laposte_zone_address_co_cea ON fr.laposte_zone_address (co_cea);
    END IF;

    -- INSEE
    IF index_exists('fr', 'idx_za_co_insee_com_arr') AND NOT index_exists('fr', 'ix_laposte_zone_address_co_insee_commune') THEN
        ALTER INDEX idx_za_co_insee_com_arr RENAME TO ix_laposte_zone_address_co_insee_commune;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_co_insee_commune ON fr.laposte_zone_address (co_insee_commune);
    END IF;

    -- old INSEE (used by IRISation)
    --	TEST : EXPLAIN SELECT * FROM fr.laposte_zone_address AS za WHERE za.co_insee_commune = 'XXXXX' AND za.co_insee_commune_precedente = 'XXXXX'
    --	necessary COALESCE(commune_precedente, '') for use w/ NULL values
    IF index_exists('fr', 'idx_za_co_insee_com_arr_anc') AND NOT index_exists('fr', 'ix_laposte_zone_address_co_insee_commune_anc') THEN
        ALTER INDEX idx_za_co_insee_com_arr_anc RENAME TO ix_laposte_zone_address_co_insee_commune_anc;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_co_insee_commune_anc ON fr.laposte_zone_address (co_insee_commune, COALESCE(co_insee_commune_precedente, ''));
    END IF;

    -- department (not useful)
    --CREATE INDEX IF NOT EXISTS idx_za_co_insee_departement ON fr.laposte_zone_address (co_insee_departement);
    DROP INDEX IF EXISTS fr.idx_za_co_insee_departement;
    -- co_insee_commune + ?
    DROP INDEX IF EXISTS fr.idx_za_co_insee_com_arr_com_arr_anc;

    -- zip code
    IF index_exists('fr', 'idx_za_co_postal') AND NOT index_exists('fr', 'ix_laposte_zone_address_co_postal') THEN
        ALTER INDEX idx_za_co_postal RENAME TO ix_laposte_zone_address_co_postal;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_co_postal ON fr.laposte_zone_address (co_postal);
    END IF;

    -- similar labels
    -- lb_l5_nn
    IF index_exists('fr', 'idx_za_lb_l5_nn') AND NOT index_exists('fr', 'ix_laposte_zone_address_lb_l5_nn') THEN
        ALTER INDEX idx_za_lb_l5_nn RENAME TO ix_laposte_zone_address_lb_l5_nn;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_lb_l5_nn ON fr.laposte_zone_address USING GIN(lb_l5_nn GIN_TRGM_OPS);
    END IF;
    -- lb_in_ext_loc
    IF index_exists('fr', 'idx_za_lb_in_ext_loc') AND NOT index_exists('fr', 'ix_laposte_zone_address_lb_in_ext_loc') THEN
        ALTER INDEX idx_za_lb_in_ext_loc RENAME TO ix_laposte_zone_address_lb_in_ext_loc;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_lb_in_ext_loc ON fr.laposte_zone_address USING GIN(lb_in_ext_loc GIN_TRGM_OPS);
    END IF;
    -- lb_nn
    IF index_exists('fr', 'idx_za_lb_nn') AND NOT index_exists('fr', 'ix_laposte_zone_address_lb_nn') THEN
        ALTER INDEX idx_za_lb_nn RENAME TO ix_laposte_zone_address_lb_nn;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_lb_nn ON fr.laposte_zone_address USING GIN(lb_nn GIN_TRGM_OPS);
    END IF;
    -- lb_ach_nn
    IF index_exists('fr', 'idx_za_lb_ach_nn') AND NOT index_exists('fr', 'ix_laposte_zone_address_lb_ach_nn') THEN
        ALTER INDEX idx_za_lb_ach_nn RENAME TO ix_laposte_zone_address_lb_ach_nn;
    ELSE
        CREATE INDEX IF NOT EXISTS ix_laposte_zone_address_lb_ach_nn ON fr.laposte_zone_address USING GIN(lb_ach_nn GIN_TRGM_OPS);
    END IF;

    -- date history
    DROP INDEX IF EXISTS fr.idx_za_histo_key;
    --CREATE UNIQUE INDEX IF NOT EXISTS idx_za_histo_key ON fr.laposte_zone_address_histo (co_cea, dt_reference);
END
$proc$ LANGUAGE plpgsql;

DO $$
BEGIN
    -- manage indexes
    CALL fr.setLaPosteIndexZoneAddress();
END
$$;
