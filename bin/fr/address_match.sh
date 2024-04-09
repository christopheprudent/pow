#!/usr/bin/env bash

    #--------------------------------------------------------------------------
    # synopsis
    #--
    # match FR addresses

match_info() {
    bash_args \
        --args_p "
            steps_info:Table des libellés des étapes;
            steps_id:Entrée dans cette table
        " \
        --args_o '
            steps_info;
            steps_id
        ' \
        "$@" || return $ERROR_CODE

    local -n _steps_ref=$get_arg_steps_info

    log_info "demande de Rapprochement (étape ${_steps_ref[$get_arg_steps_id]})"
    return $SUCCESS_CODE
}

bash_args \
    --args_p "
        file_path:Fichier Adresses à rapprocher;
        force:Forcer le traitement même si celui-ci a déjà été fait;
        format:Dépôt du fichier de format (ou chemin absolu);
        import_options:Options import (du fichier) spécifiques à son type;
        import_limit:Limiter à n enregistrements;
        steps:Ensemble des étapes à réaliser (séparées par une virgule, si plusieurs)
    " \
    --args_o '
        file_path
    ' \
    --args_v '
        force:yes|no
    ' \
    --args_d '
        force:no;
        steps:ALL
    ' \
    "$@" || exit $ERROR_CODE

declare -A match_var=(
    [FORCE]=$get_arg_force
    [FILE_PATH]="$get_arg_file_path"
    [FORMAT]="$get_arg_format"
    [IMPORT_OPTIONS]="$get_arg_import_options"
    [IMPORT_LIMIT]=$get_arg_import_limit
    [TABLE_NAME]=''
    [FORMAT_PATH]=''
    [FORMAT_SQL]=''
    [STEPS]=${get_arg_steps// /}
)
_k=0
MATCH_REQUEST_ID=$((_k++))
MATCH_REQUEST_SUFFIX=$((_k++))
MATCH_REQUEST_NEW=$((_k++))
MATCH_REQUEST_ITEMS=$_k
declare -a match_request

MATCH_STEPS=IMPORT,STANDARDIZE,MATCH_CODE,MATCH_ELEMENT,MATCH_ADDRESS,REPORT,STATS
declare -a match_steps
[ "${match_var[STEPS]}" = ALL ] && match_var[STEPS]=$MATCH_STEPS
match_steps=( ${match_var[STEPS]//,/ } )
declare -a match_steps_info=(
    [0]=Chargement
    [1]=Standardisation
    [2]=Calcul MATCH CODE
    [3]=Rapprochement ELEMENT
    [4]=Rapprochement ADRESSE
    [5]=Rapport
    [6]=Statistiques
)
expect file "${match_var[FILE_PATH]}" &&
set_env --schema_name fr &&
execute_query \
    --name ADD_MATCH_REQUEST \
    --query "
        SELECT CONCAT_WS(' ', id, suffix, new_request)
        FROM fr.add_address_match(file_path => '${match_var[FILE_PATH]}')
    " \
    --psql_arguments 'tuples-only:pset=format=unaligned' \
    --return _request &&
match_request=($_request) &&
[ ${#match_request[*]} -eq $MATCH_REQUEST_ITEMS ] || {
    log_error "demande Rapprochement fichier '${match_var[FILE_PATH]}' en erreur"
    exit $ERROR_CODE
}

match_var[TABLE_NAME]=address_match_${match_request[$MATCH_REQUEST_SUFFIX]}
match_var[FORMAT_PATH]="${POW_DIR_BIN}/${match_var[FORMAT]}_format.sql"

{
    in_array match_steps IMPORT _steps_id && {
        ([ match_var[FORCE] = no ] && table_exists --schema_name fr --table_name ${match_var[TABLE_NAME]}) || {
            match_info --steps_info match_steps_info --steps_id _steps_id &&
            import_file \
                --file_path "${match_var[FILE_PATH]}" \
                --schema_name fr \
                --table_name ${match_var[TABLE_NAME]} \
                --load_mode OVERWRITE_TABLE \
                --limit "${match_var[IMPORT_LIMIT]}" \
                --import_options "${match_var[IMPORT_OPTIONS]}"
        }
    } || true
} &&
{
    in_array match_steps STANDARDIZE _steps_id && {
        [ -f "${match_var[FORMAT_PATH]}" ] &&
        match_var[FORMAT_SQL]=$(cat "${match_var[FORMAT_PATH]}") || {
            [ -f "${match_var[FORMAT]}" ] &&
            match_var[FORMAT_SQL]=$(cat "${match_var[FORMAT]}") || {
                log_error "Le format ${match_var[FORMAT]} n'existe pas"
                false
            }
        } &&
        match_info --steps_info match_steps_info --steps_id _steps_id &&
        execute_query \
            --name STANDARDIZE_REQUEST \
            --query "CALL set_match_standardize(
                file_path => '${match_var[FILE_PATH]}'
                , mapping => '${match_var[FORMAT_SQL]}'::HSTORE
                , force => ('${match_var[FORCE]}' = 'yes')
            )"
    } || true
} &&
{
    in_array match_steps MATCH_CODE _steps_id && {
        match_info --steps_info match_steps_info --steps_id _steps_id &&
        execute_query \
            --name MATCH_CODE_REQUEST \
            --query "CALL fr.set_match_code(
                id => ${match_request[$MATCH_REQUEST_ID]}
                , force => ('${match_var[FORCE]}' = 'yes')
            )"
    } || true
} || exit $ERROR_CODE

exit $SUCCESS_CODE
