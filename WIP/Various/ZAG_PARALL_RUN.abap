FUNCTION zbp_parallel_run.
*"----------------------------------------------------------------------
*"*"Interfaccia locale:
*"  IMPORTING
*"     VALUE(XV_PROGRAM) TYPE  SYREPID
*"     VALUE(XV_FORM) TYPE  CHAR30
*"     VALUE(XV_KEY) TYPE  INDX_SRTFD
*"----------------------------------------------------------------------

    PERFORM (xv_form) IN PROGRAM (xv_program)
        USING xv_key.

    CALL FUNCTION 'DB_COMMIT'.

ENDFUNCTION.