REPORT zbp_parallel_test.

INCLUDE zbp_parall_incl.

TYPES: BEGIN OF ty_row,
         sema TYPE icon_d,
         id   TYPE i,
       END OF ty_row,
       tt_row TYPE STANDARD TABLE OF ty_row WITH DEFAULT KEY.

DATA: gt_master TYPE tt_row,
      gt_result TYPE tt_row,
      gv_id     TYPE i.

PARAMETERS: p_rows TYPE i DEFAULT 2000,
            p_mod  TYPE i DEFAULT 2.
SELECT-OPTIONS s_id FOR gv_id DEFAULT 1 TO 1000.

START-OF-SELECTION.

  IF p_mod <= 0.
    MESSAGE 'p_mod deve essere > 0' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  " Tutte rosse in partenza
  gt_master = VALUE #( FOR i = 1 UNTIL i > p_rows
                       ( sema = icon_red_light id = i ) ).

  PERFORM schedule_job_template
    USING    gt_master sy-repid 'ELAB_CHUNK'
    CHANGING gt_result.

END-OF-SELECTION.

  SORT gt_result BY id.

  DATA(lv_red)  = REDUCE i( INIT n = 0 FOR r IN gt_result
                            WHERE ( sema = icon_red_light )    NEXT n = n + 1 ).
  DATA(lv_yel)  = REDUCE i( INIT n = 0 FOR r IN gt_result
                            WHERE ( sema = icon_yellow_light ) NEXT n = n + 1 ).
  DATA(lv_grn)  = REDUCE i( INIT n = 0 FOR r IN gt_result
                            WHERE ( sema = icon_green_light )  NEXT n = n + 1 ).
  DATA(lv_out)  = REDUCE i( INIT n = 0 FOR r IN gt_result
                            WHERE ( sema = icon_light_out )    NEXT n = n + 1 ).

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = DATA(lo_alv)
        CHANGING  t_table      = gt_result ).

      DATA(lo_cols) = lo_alv->get_columns( ).
      DATA(lo_col)  = CAST cl_salv_column_table( lo_cols->get_column( 'SEMA' ) ).
      lo_col->set_icon( if_salv_c_bool_sap=>true ).
      lo_col->set_short_text( 'Stato' ).
      lo_cols->set_optimize( ).

      lo_alv->get_display_settings( )->set_list_header(
        |in { lines( gt_master ) } out { lines( gt_result ) } - rosse { lv_red } gialle { lv_yel } verdi { lv_grn } fuori range { lv_out }| ).

      lo_alv->display( ).
    CATCH cx_salv_error INTO DATA(lx_salv).
      MESSAGE lx_salv->get_text( ) TYPE 'E'.
  ENDTRY.

FORM elab_chunk USING xv_key TYPE indx_srtfd.
  DATA: lt_chunk  TYPE tt_row,
        lt_params TYPE STANDARD TABLE OF rsparams,
        ls_indx   TYPE indx.

  IMPORT chunk = lt_chunk params = lt_params
    FROM DATABASE indx(zi) TO ls_indx ID xv_key.
  IF sy-subrc <> 0.
    MESSAGE 'Chunk non trovato nel cluster' TYPE 'A'.
  ENDIF.

  PERFORM zbp_set_selscreen USING lt_params.

  LOOP AT lt_chunk ASSIGNING FIELD-SYMBOL(<ls_row>).
    PERFORM elab_row CHANGING <ls_row>.
  ENDLOOP.

  EXPORT result = lt_chunk
    TO DATABASE indx(zo) FROM ls_indx ID xv_key.
ENDFORM.

FORM elab_row CHANGING cs_row TYPE ty_row.
  IF cs_row-id NOT IN s_id.
    cs_row-sema = icon_light_out.          " fuori dal range s_id
  ELSEIF cs_row-id MOD p_mod = 0.
    cs_row-sema = icon_yellow_light.       " multiplo di p_mod
  ELSE.
    cs_row-sema = icon_green_light.
  ENDIF.
ENDFORM.