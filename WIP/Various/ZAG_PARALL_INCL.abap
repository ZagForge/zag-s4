SPAN {
font-family: "Consolas";
font-size: 10pt;
color: #000000;
background: #FFFFFF;
}
.L0S31 {
font-style: italic;
color: #808080;
}
.L0S32 {
color: #3399FF;
}
.L0S33 {
color: #4DA619;
}
.L0S52 {
font-weight: bold;
color: #0000FF;
}
.L0S55 {
color: #800080;
}
.L0S70 {
color: #808080;
}

*&---------------------------------------------------------------------*
*& ZBP_PARALL_INCL - Esecuzione parallela a chunk
*&
*& Output: gt_result (ordine non garantito), gt_task_reg (L/O/E + msg)
*& Check:  lines( gt_result ) = lines( gt_master )
*& Param:  p_njob = max task, p_recjob = righe per chunk
*&
*& Regole
*&  - Master e result: tabelle diverse, stesso tipo riga, globali
*&  - Il task gira in una sessione nuova: elab_row vede solo la riga e
*&    parametri/select-option della selection screen (esportati dal
*&    template, ripristinati da zbp_set_selscreen). Altre globali: vuote
*&  - Catturare le eccezioni in elab_row: un dump perde l'intero chunk
*&  - Cluster fissi: chunk / params / result, aree ZI / ZO
*&  - elab_chunk nello stesso report passato in sy-repid, report attivo
*&  - Una schedule_job_template alla volta; fa DB_COMMIT
*&
*& Uso nel report
*&   TYPES: BEGIN OF ty_row, ... END OF ty_row,
*&          tt_row TYPE STANDARD TABLE OF ty_row WITH DEFAULT KEY.
*&   DATA: gt_master TYPE tt_row, gt_result TYPE tt_row.
*&
*&   PERFORM schedule_job_template
*&     USING gt_master sy-repid 'ELAB_CHUNK' CHANGING gt_result.
*&
*&   FORM elab_chunk USING xv_key TYPE indx_srtfd.
*&     DATA: lt_chunk  TYPE tt_row,
*&           lt_params TYPE STANDARD TABLE OF rsparams,
*&           ls_indx   TYPE indx.
*&
*&     IMPORT chunk = lt_chunk params = lt_params
*&       FROM DATABASE indx(zi) TO ls_indx ID xv_key.
*&
*&     PERFORM zbp_set_selscreen USING lt_params.
*&
*&     LOOP AT lt_chunk ASSIGNING FIELD-SYMBOL(<ls_row>).
*&       PERFORM elab_row CHANGING <ls_row>.
*&     ENDLOOP.
*&
*&     EXPORT result = lt_chunk
*&       TO DATABASE indx(zo) FROM ls_indx ID xv_key.
*&
*&   ENDFORM.
*&
*&   FORM elab_row CHANGING cs_row TYPE ty_row.
*&     " logica per riga, usa p_xxx / s_xxx direttamente
*&   ENDFORM.
*&---------------------------------------------------------------------*


" Registro dei task: una riga per chunk lanciato
TYPES: BEGIN OF ty_task_reg,
         task   TYPE c LENGTH 32,
         key    TYPE indx_srtfd,    " chiave del cluster INDX di questo chunk
         status TYPE c LENGTH 1,     " L=lanciato, O=ok, E=errore
         msg    TYPE char255,
       END OF ty_task_reg.

DATA: gv_active_tasks TYPE i,       " task in corso (slot occupati)
      gt_task_reg     TYPE HASHED TABLE OF ty_task_reg WITH UNIQUE KEY task,
      gr_result       TYPE REF TO data.   " puntatore al result, usato dal callback

SELECTION-SCREEN BEGIN OF BLOCK z1 WITH FRAME TITLE text-001.
PARAMETERS: p_njob   TYPE i DEFAULT 50 OBLIGATORY,
            p_recjob TYPE i DEFAULT 100 OBLIGATORY.
SELECTION-SCREEN END OF BLOCK z1.

*&---------------------------------------------------------------------*
*& Spezza la master in chunk, ne scrive uno alla volta nel cluster INDX
*& e lancia un task asincrono per chunk. Torna quando tutti i task sono
*& finiti. I risultati arrivano in yt_result tramite zbp_task_callback.
*&---------------------------------------------------------------------*
FORM schedule_job_template USING    xt_master_data TYPE STANDARD TABLE
                                    xv_program     TYPE syrepid
                                    xv_form        TYPE char30
                           CHANGING yt_result      TYPE STANDARD TABLE.

  DATA: lr_chunk TYPE REF TO data,
        ls_indx  TYPE indx,
        lv_key   TYPE indx_srtfd,
        lv_cnt   TYPE i,
        lv_from  TYPE i VALUE 1,
        lv_to    TYPE i,
        lv_total TYPE i,
        lv_task  TYPE c LENGTH 32,
        lv_ok    TYPE abap_bool.

  FIELD-SYMBOLS <lt_chunk> TYPE STANDARD TABLE.

  " Reset dello stato e puntatore al result per il callback
  CLEAR: yt_result, gt_task_reg, gv_active_tasks.
  GET REFERENCE OF yt_result INTO gr_result.

  " Tabella chunk con lo stesso tipo della master, senza conoscerlo
  CREATE DATA lr_chunk LIKE xt_master_data.
  ASSIGN lr_chunk->* TO <lt_chunk>.

  lv_total = lines( xt_master_data ).


  DATA lt_params TYPE STANDARD TABLE OF rsparams.

  " Selection screen del report: viaggia nel cluster insieme al chunk
  CALL FUNCTION 'RS_REFRESH_FROM_SELECTOPTIONS'
    EXPORTING
      curr_report     = xv_program
    TABLES
      selection_table = lt_params
    EXCEPTIONS
      OTHERS          = 1.

  WHILE lv_from <= lv_total.
    " Estremi del chunk corrente
    lv_to = nmin(
              val1 = lv_from + p_recjob - 1
              val2 = lv_total
            ).

    CLEAR <lt_chunk>.
    APPEND LINES OF xt_master_data FROM lv_from TO lv_to TO <lt_chunk>.

    " Chunk -> cluster INDX con chiave univoca; il commit lo rende
    " visibile al task, che usa un'altra connessione DB
    lv_key  = cl_system_uuid=>create_uuid_c22_static( ).
    ls_indx = VALUE #(
                aedat = sy-datum
                usera = sy-uname
                pgmid = xv_program
              ).

    EXPORT chunk  = <lt_chunk>
           params = lt_params
      TO DATABASE indx(zi) FROM ls_indx ID lv_key.
    CALL FUNCTION 'DB_COMMIT'.

    " Aspetta che si liberi uno slot (max p_njob task attivi)
    DO.
      WAIT FOR ASYNCHRONOUS TASKS UNTIL gv_active_tasks < p_njob UP TO 60 SECONDS.
      IF gv_active_tasks < p_njob.
        EXIT.
      ENDIF.
    ENDDO.

    " Registra il task prima del lancio, il callback lo ritrova per nome
    lv_cnt  = lv_cnt + 1.
    lv_task = |T{ lv_cnt WIDTH = 6 PAD = '0' }|.
    INSERT VALUE #( task = lv_task key = lv_key status = 'L' )
      INTO TABLE gt_task_reg.

    " Lancio con retry: riprova se non ci sono risorse o la comunicazione fallisce
    lv_ok = abap_false.
    DO 5 TIMES.
      gv_active_tasks = gv_active_tasks + 1.
      CALL FUNCTION 'ZBP_PARALLEL_RUN'
        STARTING NEW TASK lv_task
        PERFORMING zbp_task_callback ON END OF TASK
        EXPORTING
          xv_program            = xv_program
          xv_form               = xv_form
          xv_key                = lv_key
        EXCEPTIONS
          communication_failure = 1
          system_failure        = 2
          resource_failure      = 3
          OTHERS                = 4.
      IF sy-subrc = 0.
        lv_ok = abap_true.
        EXIT.
      ENDIF.
      " Lancio fallito: rilascia lo slot e riprova dopo una pausa
      gv_active_tasks = gv_active_tasks - 1.
      WAIT UP TO 2 SECONDS.
    ENDDO.

    " Dopo 5 tentativi: segna il chunk in errore e pulisci il cluster
    IF lv_ok = abap_false.
      ASSIGN gt_task_reg[ task = lv_task ] TO FIELD-SYMBOL(<ls_reg>).
      <ls_reg>-status = 'E'.
      <ls_reg>-msg    = 'Lancio fallito dopo 5 tentativi'.
      DELETE FROM DATABASE indx(zi) ID lv_key.
    ENDIF.

    lv_from = lv_to + 1.
  ENDWHILE.

  " Aspetta i task ancora in corso; i callback girano durante il WAIT
  WAIT FOR ASYNCHRONOUS TASKS UNTIL gv_active_tasks = 0 UP TO 300 SECONDS.
  CALL FUNCTION 'DB_COMMIT'.
ENDFORM.

*&---------------------------------------------------------------------*
*& Callback di fine task. Gira nella sessione del report, non nel task.
*& Legge il risultato dal cluster, lo accoda in yt_result, aggiorna lo
*& stato in gt_task_reg, pulisce il cluster e libera lo slot.
*&---------------------------------------------------------------------*
FORM zbp_task_callback USING xv_task TYPE c.

  DATA: lv_msg  TYPE char255,
        lr_part TYPE REF TO data,
        ls_indx TYPE indx.

  FIELD-SYMBOLS: <lt_res>  TYPE STANDARD TABLE,
                 <lt_part> TYPE STANDARD TABLE.

  " Recupera l'esito tecnico del task (errori di comunicazione o dump)
  RECEIVE RESULTS FROM FUNCTION 'ZBP_PARALLEL_RUN'
    EXCEPTIONS
      communication_failure = 1 MESSAGE lv_msg
      system_failure        = 2 MESSAGE lv_msg
      OTHERS                = 3.
  DATA(lv_subrc) = sy-subrc.

  " Ritrova il chunk dal nome del task
  ASSIGN gt_task_reg[ task = xv_task ] TO FIELD-SYMBOL(<ls_reg>).
  IF sy-subrc = 0.

    IF lv_subrc = 0.
      " Task ok: tabella di appoggio con lo stesso tipo del result
      ASSIGN gr_result->* TO <lt_res>.
      CREATE DATA lr_part LIKE <lt_res>.
      ASSIGN lr_part->* TO <lt_part>.

      " Legge il risultato scritto dal task e lo accoda al result
      TRY.
          IMPORT result = <lt_part>
            FROM DATABASE indx(zo) TO ls_indx ID <ls_reg>-key.
          IF sy-subrc = 0.
            APPEND LINES OF <lt_part> TO <lt_res>.
            <ls_reg>-status = 'O'.
          ELSE.
            <ls_reg>-status = 'E'.
            <ls_reg>-msg    = 'Risultato assente nel cluster'.
          ENDIF.
        CATCH cx_sy_import_mismatch_error INTO DATA(lx_imp).
          " Il tipo riga esportato dal report non coincide con quello del result
          <ls_reg>-status = 'E'.
          <ls_reg>-msg    = lx_imp->get_text( ).
      ENDTRY.
    ELSE.
      " Task fallito: registra il messaggio tecnico
      <ls_reg>-status = 'E'.
      <ls_reg>-msg    = lv_msg.
    ENDIF.

    " Pulizia del cluster del chunk, in ogni caso
    DELETE FROM DATABASE indx(zi) ID <ls_reg>-key.
    DELETE FROM DATABASE indx(zo) ID <ls_reg>-key.
  ENDIF.

  " Libera lo slot: sblocca il WAIT del template
  gv_active_tasks = gv_active_tasks - 1.
ENDFORM.

*&---------------------------------------------------------------------*
*& Ripristina nel task i valori della selection screen del report.
*& Chiamare in elab_chunk dopo l'IMPORT.
*&---------------------------------------------------------------------*
FORM zbp_set_selscreen USING xt_params TYPE STANDARD TABLE. " tipo da passare: STANDARD TABLE OF rsparams

  DATA lv_name TYPE string.

  FIELD-SYMBOLS: <ls_par>  TYPE rsparams,
                 <lv_par>  TYPE any,
                 <lt_sel>  TYPE STANDARD TABLE,
                 <ls_sel>  TYPE any,
                 <lv_comp> TYPE any.

  " Svuota prima i select-option
  LOOP AT xt_params ASSIGNING <ls_par>.
    CHECK <ls_par>-kind = 'S'.
    lv_name = |{ <ls_par>-selname }[]|.
    ASSIGN (lv_name) TO <lt_sel>.
    IF sy-subrc = 0.
      CLEAR <lt_sel>.
    ENDIF.
  ENDLOOP.

  LOOP AT xt_params ASSIGNING <ls_par>.
    CASE <ls_par>-kind.

      WHEN 'P'.
        lv_name = <ls_par>-selname.
        ASSIGN (lv_name) TO <lv_par>.
        IF sy-subrc = 0.
          <lv_par> = <ls_par>-low.
        ENDIF.

      WHEN 'S'.
        lv_name = |{ <ls_par>-selname }[]|.
        ASSIGN (lv_name) TO <lt_sel>.
        IF sy-subrc = 0.
          APPEND INITIAL LINE TO <lt_sel> ASSIGNING <ls_sel>.
          ASSIGN COMPONENT 'SIGN'   OF STRUCTURE <ls_sel> TO <lv_comp>.
          <lv_comp> = <ls_par>-sign.
          ASSIGN COMPONENT 'OPTION' OF STRUCTURE <ls_sel> TO <lv_comp>.
          <lv_comp> = <ls_par>-option.
          ASSIGN COMPONENT 'LOW'    OF STRUCTURE <ls_sel> TO <lv_comp>.
          <lv_comp> = <ls_par>-low.
          ASSIGN COMPONENT 'HIGH'   OF STRUCTURE <ls_sel> TO <lv_comp>.
          <lv_comp> = <ls_par>-high.
        ENDIF.

    ENDCASE.
  ENDLOOP.
ENDFORM.