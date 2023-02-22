#!/usr/bin/env bash

    #--------------------------------------------------------------------------
    # synopsis
    #--
    # import INSEE administrative cuttings (into INSEE schema)

bash_args \
    --args_p "
        force:Forcer l'import même si celui-ci a déjà été fait;
        year:Importer un millésime spécifique (au format YY ou ALL pour tous) au lieu du dernier millésime disponible;
        load_mode:Mode de chargement des données
    " \
    --args_v '
        force:yes|no;
        load_mode:OVERWRITE|APPEND
    ' \
    --args_d '
        force:no;
        load_mode:APPEND
    ' \
    "$@" || exit $ERROR_CODE

co_type_import=INSEE_DECOUPAGE_COMMUNAL
force="$get_arg_force"
load_mode="$get_arg_load_mode"
# year of administrative cutting (w/ YY format)
year=

on_import_error() {
    # import created?
    [ "$POW_DEBUG" = yes ] && { echo "year_history_id=$year_history_id"; }
    [ -n "$year_history_id" ] && io_history_end_ko --id $year_history_id

    # ignoring error if last year already exists
    if io_history_exists --type $co_type_import --date_end "${years[$year_id]}"; then
        if [ -z "$get_arg_year" ]; then
            log_info "Erreur ignorée car le millésime de l'année courante (${year}) a déjà été importé avec succès"
        else
            log_info "Erreur ignorée car le millésime demandé (${year}) a déjà été importé avec succès"
        fi
        exit $SUCCESS_CODE
    fi

    log_error "Erreur import du millésime (${year})"
    exit $ERROR_CODE
}

# get years
io_get_list_online_available \
    --type_import $co_type_import \
    --details_file years_list_path \
    --dates_list years || exit $ERROR_CODE
[ "$POW_DEBUG" = yes ] && { declare -p years; declare -p years_list_path; }

# get year (w/ format YY)
if [ -z "$get_arg_year" ]; then
    # get more recent
    year_id=0
elif [ "$get_arg_year" = ALL ]; then
    # get all available
    load_mode_all=$load_mode
    for _year in ${years[@]}; do
        _yy=$(date -d _year +%y)
        $POW_DIR_BATCH/insee_administrative_cutting.sh \
            --year $_yy \
            --load_mode $load_mode_all \
            --force $force || exit $ERROR_CODE
        load_mode_all=APPEND
    done
    exit $SUCCESS_CODE
else
    in_array years "$(date +%C)${get_arg_year}-01-01" year_id || {
        log_error "Impossible de trouver le millésime $get_arg_year de $co_type_import, les millésimes disponibles sont ${years[@]}"
        on_import_error
    }
fi
year=$(date -d ${years[$year_id]} +%y)
[ -z "$year" ] && {
    log_error "Impossible de trouver le millésime de $co_type_import"
    on_import_error
}
[ "$POW_DEBUG" = yes ] && { echo "year=$year (${years[$year_id]})"; }

url_data=$(grep --only-matching --perl-regexp "/fr/statistiques/fichier/2028028/table-appartenance-geo-communes-${year}[^.]*\.zip" "$years_list_path" | head --lines 1)
url_data="https://www.insee.fr/${url_data}"
year_data=$(basename "$url_data")
rm --force "$years_list_path"

set_env --schema_code insee &&
io_todo \
    --force $get_arg_force \
    --type $co_type_import \
    --date_end "${years[$year_id]}"
case $? in
$POW_IO_SUCCESSFUL)
    exit $SUCCESS_CODE
    ;;
$POW_IO_IN_PROGRESS | $POW_IO_ERROR | $ERROR_CODE)
    on_import_error
    ;;
esac

# from 2014 to now
name_worksheet_municipality=COM
name_worksheet_district=ARM
name_worksheet_supra=Zones_supra_communales
line_number_supra=6
# before 2011 (included)
if [ $year -le 11 ]; then
    name_worksheet_municipality=Liste_COM
    name_worksheet_district=
    name_worksheet_supra=Niv_supracom
    line_number_supra=5
# 2012 and 2013
elif [ $year -le 13 ]; then
    name_worksheet_municipality='Emboîtements communaux'
    name_worksheet_district=
    name_worksheet_supra='Zones supra-communales'
fi

log_info "Import du millésime $year de $co_type_import" &&
{
    case "$load_mode" in
    OVERWRITE)
        execute_query \
            --name "DELETE_IO_${co_type_import}" \
            --query "DELETE FROM io_history WHERE co_type = '${co_type_import}'"
        ;;
    APPEND)
        execute_query \
            --name "DELETE_IO_${co_type_import}_${year}" \
            --query "
                DELETE FROM io_history
                WHERE co_type = '${co_type_import}' AND dt_data_begin = '${years[$year_id]}'"
        ;;
    esac
} &&
io_history_begin \
    --type $co_type_import \
    --date_begin "${years[$year_id]}" \
    --date_end "${years[$year_id]}" \
    --nrows_todo 35000 \
    --id year_history_id &&
io_download_file --url "$url_data" --output_directory "$POW_DIR_IMPORT" &&
year_ressource="$POW_DIR_IMPORT/$year_data" &&
{
    [ "$POW_DEBUG" = yes ] && { echo "year_ressource=$year_ressource"; } || true
} &&
import_file \
    --file_path "$year_ressource" \
    --import_options "worksheet_name:${name_worksheet_municipality};from_line_number:6" \
    --table_name administrative_cutting_municipality_tmp \
    --load_mode OVERWRITE_TABLE &&
{
    execute_query \
        --name MUNICIPALITY_ADD_COLUMNS_EPCI \
        --query '
            ALTER TABLE insee.administrative_cutting_municipality_tmp
                ADD COLUMN IF NOT EXISTS "EPCI" VARCHAR;
            ALTER TABLE insee.administrative_cutting_municipality_tmp
                ADD COLUMN IF NOT EXISTS "NATURE_EPCI" VARCHAR;
            '
} &&
import_file \
    --file_path "$year_ressource" \
    --import_options "worksheet_name:${name_worksheet_supra};from_line_number:${line_number_supra}" \
    --table_name administrative_cutting_supra_tmp \
    --load_mode OVERWRITE_TABLE &&
{
    {
        # before 2011 (included)
        if [ $year -le 11 ]; then
            execute_query \
                --name SUPRA_RENAME_COLUMNS \
                --query '
                    ALTER TABLE insee.administrative_cutting_supra_tmp
                        RENAME COLUMN "Code géographique" TO "CODGEO";
                    ALTER TABLE insee.administrative_cutting_supra_tmp
                        RENAME COLUMN "Niveau géographique" TO "NIVGEO";
                    ALTER TABLE insee.administrative_cutting_supra_tmp
                        RENAME COLUMN "Libellé géographique" TO "LIBGEO";
                    '
        fi
    } &&
    {
        if [ -n "$name_worksheet_district" ]; then
            import_file \
                --file_path "$year_ressource" \
                --import_options "worksheet_name:${name_worksheet_district};from_line_number:6" \
                --table_name administrative_cutting_district_tmp \
                --load_mode OVERWRITE_TABLE &&
            execute_query \
                --name DISTRICT_ADD_COLUMNS_EPCI \
                --query '
                    ALTER TABLE insee.administrative_cutting_district_tmp
                        ADD COLUMN IF NOT EXISTS "EPCI" VARCHAR;
                    ALTER TABLE insee.administrative_cutting_district_tmp
                        ADD COLUMN IF NOT EXISTS "NATURE_EPCI" VARCHAR;
                    '
        else
            # before 2013 (included) : no district (included into supra)
            execute_query \
                --name DISTRICT_CREATE_TMP \
                --query '
                    DROP TABLE IF EXISTS insee.administrative_cutting_district_tmp;
                    CREATE TABLE insee.administrative_cutting_district_tmp AS (
                        SELECT
                            arm."CODGEO"
                            ,arm."LIBGEO"
                            ,com_globale_arm."CODGEO" AS "COM"
                            ,com_globale_arm."DEP"
                            ,com_globale_arm."REG"
                            ,com_globale_arm."EPCI"
                            ,com_globale_arm."NATURE_EPCI"
                            ,com_globale_arm."ARR"
                            ,com_globale_arm."CV"
                        FROM insee.administrative_cutting_supra_tmp AS arm
                        INNER JOIN insee.administrative_cutting_municipality_tmp AS com_globale_arm
                            ON com_globale_arm."CODGEO" = (
                                CASE LEFT(arm."CODGEO",3)
                                WHEN '"'"'132'"'"' THEN '"'"'13055'"'"' /*Marseille*/
                                WHEN '"'"'693'"'"' THEN '"'"'69123'"'"' /*Lyon*/
                                WHEN '"'"'751'"'"' THEN '"'"'75056'"'"' /*Paris*/
                                END
                            )
                        WHERE arm."NIVGEO" = '"'"'ARM'"'"'
                    );
                    DELETE FROM insee.administrative_cutting_supra_tmp
                        WHERE "NIVGEO" = '"'"'ARM'"'"';
                    '
        fi
    }
} &&
execute_query \
    --name ALL_ADD_COLUMN_YEAR \
    --query "
        ALTER TABLE insee.administrative_cutting_municipality_tmp
            ADD column millesime INTEGER DEFAULT 20${year};
        ALTER TABLE insee.administrative_cutting_district_tmp
            ADD column millesime INTEGER DEFAULT 20${year};
        ALTER TABLE insee.administrative_cutting_supra_tmp
            ADD column millesime INTEGER DEFAULT 20${year};
        " &&
{
    case "$load_mode" in
    OVERWRITE)
        execute_query \
            --name TRUNCATE_DATA \
            --query '
                TRUNCATE TABLE insee.administrative_cutting_municipality_and_district;
                TRUNCATE TABLE insee.administrative_cutting_supra;"
                '
        ;;
    APPEND)
        execute_query \
            --name DELETE_YEAR \
            --query "
                DELETE FROM insee.administrative_cutting_municipality_and_district
                    WHERE millesime = '20${year}';
                DELETE FROM insee.administrative_cutting_supra
                    WHERE millesime = '20${year}';"
        ;;
    esac
} &&
execute_query \
    --name ADMINISTRATIVE_CUTTING \
    --query "$POW_DIR_BATCH/insee_adminitrative_cutting.sql" &&
execute_query \
    --name DROP_TMP \
    --query '
        DROP TABLE insee.administrative_cutting_municipality_tmp;
        DROP TABLE insee.administrative_cutting_district_tmp;
        DROP TABLE insee.administrative_cutting_supra_tmp;
        ' &&
io_history_end_ok \
    --nrows_processed '
        (
            (SELECT COUNT(*) FROM insee.administrative_cutting_municipality_and_district)+
            (SELECT COUNT(*) FROM insee.administrative_cutting_supra)
        )
        ' \
    --id $year_history_id &&
vacuum \
    --schema_name insee \
    --table_name administrative_cutting_municipality_and_district \
    --mode FULL &&
vacuum \
    --schema_name insee \
    --table_name administrative_cutting_supra \
    --mode FULL &&
rm --force "$year_ressource" || on_import_error

log_info "Import du millésime $year de $co_type_import avec succès"
exit $SUCCESS_CODE