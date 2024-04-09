/***
 * FR-ADDRESS matching address (element)
 */

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'matched_element')
    OR EXISTS (
        SELECT 1 FROM information_schema.attributes
        WHERE udt_name = 'matched_element' AND attribute_name = 'similarity_semantic')
    THEN
        DROP TYPE IF EXISTS fr.matched_element CASCADE;
        CREATE TYPE fr.matched_element AS (
              codes_address CHAR(10)[]
            , level VARCHAR                     -- AREA|STREET|HOUSENUMBER|COMPLEMENT
            , elapsed_time INTERVAL
            , status VARCHAR
            , similarity NUMERIC
        );
    END IF;
END $$;

DO $$
BEGIN
    IF NOT column_exists('fr', 'address_match_element', 'matched_element') THEN
        -- has to be rebuild!
        DROP TABLE IF EXISTS fr.address_match_element;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS fr.address_match_element (
      id SERIAL NOT NULL
    , level VARCHAR
    , match_code VARCHAR
    , matched_element fr.matched_element
);

CREATE UNIQUE INDEX IF NOT EXISTS iux_address_match_element_id ON fr.address_match_element(id);
CREATE INDEX IF NOT EXISTS ix_address_match_element_match_code ON fr.address_match_element(match_code);

-- match each element of address (of a matching request)
SELECT drop_all_functions_if_exists('fr', 'set_match_element');
CREATE OR REPLACE PROCEDURE fr.set_match_element(
      id IN INT
    , force IN BOOLEAN DEFAULT FALSE
)
AS
$proc$
DECLARE
    _is_match_element BOOLEAN;
    _nrows INTEGER;
    _info VARCHAR := CONCAT('rapprochement ELEMENT demande Rapprochement (', id, ')');
    _levels VARCHAR[] := ARRAY['AREA', 'STREET', 'HOUSENUMBER', 'COMPLEMENT'];
    _level VARCHAR;
    _element RECORD;
    _query TEXT;
    _matched_element fr.matched_element;
BEGIN
    SELECT is_match_element
    INTO _is_match_element
    FROM fr.address_match_request mr
    WHERE mr.id = set_match_element.id
    ;

    IF _is_match_element IS NULL THEN
        RAISE 'aucune demande de Rapprochement trouvée ''%''', id;
    END IF;

    IF force OR NOT _is_match_element THEN
        FOREACH _level IN ARRAY _levels
        LOOP
            -- search for element not already matched (w/ its matched parent if exists)
            _query := CONCAT(
                '
                SELECT
                    mc.level
                    , mc.match_code_element
                    , CASE $2
                        WHEN ''AREA'' THEN NULL::fr.matched_element
                        ELSE me.matched_element
                        END matched_parent
                    , (SELECT standardized_address
                        FROM fr.address_match_result
                        WHERE id_request = $1
                        AND
                        (standardized_address).match_code_', LOWER(_level), ' =
                        mc.match_code_element LIMIT 1
                    ) standardized_address
                FROM
                    fr.address_match_code mc
                '
            );
            IF _level != 'AREA' THEN
                _query := CONCAT(_query
                    , '
                        LEFT OUTER JOIN fr.address_match_element me
                            ON me.match_code = mc.match_code_parent
                    '
                );
            END IF;
            _query := CONCAT(_query
                , '
                WHERE
                    mc.id_request = $1
                    AND
                    mc.level = $2
                    AND
                    NOT EXISTS(
                        SELECT 1
                        FROM fr.address_match_element me2
                        WHERE mc.match_code_element = me2.match_code
                    )
                '
            );
            _nrows := 0;
            FOR _element IN EXECUTE _query USING id, _level
            LOOP
                -- match element
                SELECT
                    matched_element
                INTO
                    _matched_element
                FROM
                    fr.match_element(
                        level => _element.level
                        , standardized_address => _element.standardized_address
                        , matched_parent => _element.matched_parent
                    )
                ;

                -- new matched element w/ its match code
                INSERT INTO fr.address_match_element(
                      level
                    , match_code
                    , matched_element
                )
                VALUES(
                    _element.level
                    , _element.match_code_element
                    , _element.match_element
                )
                ;

                _nrows := nrows +1;
            END LOOP;
            CALL public.log_info(CONCAT(_info, ' : #%=%', _level, _nrows));
        END LOOP;

        UPDATE fr.address_match_request mr SET
            is_match_element = TRUE
            WHERE
                mr.id = set_match_element.id
        ;
    ELSE
        CALL public.log_info(CONCAT(_info, ' : déjà traitée (option force disponible)'));
    END IF;
END
$proc$ LANGUAGE plpgsql;
