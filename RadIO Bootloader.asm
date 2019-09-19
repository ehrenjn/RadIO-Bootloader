;STILL NOT SURE HOW TO TELL IT TO BEGIN EXECUTION IN THE BOOTLOADER SECTION
	;"the Boot Reset Fuse can be programmed so that the Reset Vector is pointing to the Boot Flash 
	;	start address after a reset. In this case, the Boot Loader is started after a reset."
	;basically just make the boot reset fuse = 0 
	;	and it'll reset to whatever position is indicated by the BOOTSZ1 BOOTSZ0 fuses (the fuses that control where bootloader memory begins)
	;	(I want to make the smallest bootloader possible on the 328p: 256 words
;UHHH DO I ACTUALLY NEED TO ERASE THE PAGE BEFORE I WRITE TO IT????
;EVERYTHING IS UNTESTED (of course)

;go to page 277 in atmega datasheet to read about "programming the flash"
;go to page 287 in datasheet for "Assembly Code Example for a Boot Loader"

;flash must be addressed in the Z register using pages and words
;a word is 2 bytes long, there are 64 words per page
;there are 256 pages
;when using Z to address a page, bits 13:6 specify a page and bits 5:0 specifify a word within that page
;   R31     R30
;xxpppppp ppwwwwww 

;you can only write to the flash one page at a time
;first fill the page buffer, then erase the old page, then write the new page.


.INCLUDE iodefs.asm

.EQU PAGE_LENGTH = 64
.EQU NUM_PAGES = 252 ;not 256 because last 4 pages are the bootloader itself

.EQU BAUD_RATE_HI = 0 ;baud rate bytes for USART
.EQU BAUD_RATE_LO = 0

.EQU BTN_IN_PIN = 0


.ORG SMALLBOOTSTART ;place this at the beginning of the smallest bootloader section (256 words large)


	cli ;disable all interrupts so currently bootloaded program can't interrupt bootloading process
	ldi Z, 0 ;current word in flash that we're updating
	ldi R3, 0 ;current page number

;init USART
	ldi R4, BAUD_RATE_HI 
	out UBRR0H, R4 ;init baud rate hi
	ldi R4, BAUD_RATE_LO
	out UBRR0L, R4 ;init baud rate lo
	ldi R4, 0b00010000
	out UCSR0B, R4 ;enable USART reciever mode
	ldi R4, THE FRAME FORMAT HERE WHATEVER IT IS ;AHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH
	out UCSR0C, R4

wait_for_initial_program_byte:
	sbis UCSR0A, 7 ;wait until there is there is some unread data in USART 
	rjmp wait_for_initial_program_byte



update_next_page:
	ld R2, 0 ;current word number

	recieve_byte()
	;RUN THE RECIEVE BYTE MACRO A COUPLE TIMES ON THE RIGHT REGISTERS AND STUFF

;either keep filling page buffer or write the page
	cpi R2, PAGE_LENGTH ;current word number - PAGE_LENGTH
	brsh write_page ;write page if whole page is written to buffer
	inc R2 ;otherwise, continue filling page
	inc Z
	rjmp fill_page_buffer



write_page:
	ldi R2, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, R2
	spm ;erase the page

wait_erase_complete:
	sbic SPMCSR, 0 ;skip next instruction if bit 0 of SPMCSR is cleared
	rjmp wait_erase_complete ;if SPM is still going, keep waiting

;write the current buffer to flash
	ldi R2, 0b00000101 ;enable SPM, write mode
	out SPMCSR, R2
	spm ;write the page

wait_write_complete:
	sbic SPMCSR, 0 ;skip next instruction if bit 0 of SPMCSR is cleared
	rjmp wait_write_complete ;if SPM is still going, keep waiting

;write another page or exit if max page number is reached
	cpi R3, NUM_PAGES
	brsh end_flash_write ;end flash writing if we've written all flash except the bootloader
	inc R3 ;otherwise, write another page
	inc Z ;increment Z here since we didn't do it at the end of the last buffer load
	rjmp update_next_page



end_flash_write:
	jmp 0 ;start uploaded program



;arguments:	1: the register to store the recieved byte in
;returns:	arg1: the byte that was recieved
;			R5: 0 if a byte was read, 1 otherwise
;trashes:	Y
.MACRO recieve_byte:

;initialize variables
	ldi R5, 1 ;1 indicates byte has not been recieved
	ldi Y, 0 ;counter to keep track of how long we've waited for the current byte

wait_for_byte:
;first, exit if we wait a long time without any new byte
	inc Y
	mov R4, YL ;move lo byte of Y to R4 so I can OR both bytes of Y together to check if they're 0
	or R4, YH ;check if Y == 0
	breq return ;if Y == 0 then it's been incremented 2**16 times so it's probably safe to say theres no more data coming

;check if we're still waiting for byte	
	sbis UCSR0A, 7 ;wait until there is there is some unread data in USART 
	rjmp wait_for_byte ;if theres no unread data then keep waiting

;read recieved data
	ldi R5, 0 ;let caller know that a byte was read
	in @0, UDR0 ;read byte from USART
	
return:
.ENDMACRO