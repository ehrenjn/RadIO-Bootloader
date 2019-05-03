;STILL NOT SURE HOW TO TELL IT TO BEGIN EXECUTION IN THE BOOTLOADER SECTION
;FOR USART: "The initialization process normally consists of setting the baud rate, setting frame format and enabling the Transmitter or the Receiver depending on the usage."

;go to page 277 in atmega datasheet to read about "programming the flash"
;go to page 287 in datasheet for "Assembly Code Example for a Boot Loader"

;flash must be addressed in the Z register using pages and words
;a word is 2 bytes long, there are 64 words per page
;there are 256 pages
;when using Z to address a page, bits 13:6 specify a page and bits 5:0 specifify a word within that page
;   R31     R30
;xxpppppp ppwwwwww 

.INCLUDE iodefs.asm

.EQU PAGE_LENGTH = 64
.EQU NUM_PAGES = 252 ;not 256 because last 4 pages are the bootloader itself

.EQU BTN_IN_PIN = 0


.ORG SMALLBOOTSTART ;place this at the beginning of the smallest bootloader section (256 words large)


	cli ;disable all interrupts so currently bootloaded program can't interrupt bootloading process
	ldi Z, 0 ;current word in flash that we're updating
	ldi R3, 0 ;current page number

update_next_page:
	ld R2, 0 ;current word number

fill_page_buffer:
	;PUT ANOTHER WORD INTO BUFFER HERE SOMEHOW

;either keep loading page buffer or exit and write the page
	cpi R2, PAGE_LENGTH ;current word number - PAGE_LENGTH
	brsh write_page ;write page if whole page is written to buffer
	inc R2 ;otherwise, continue filling page
	inc Z
	rjmp fill_page_buffer

write_page:
	ldi R2, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, R0
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










;Z: the location of the page to erase
flash_erase:
	push R0

;erase page specified by Z
	ldi R0, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, R0
	spm ;erase the page

;return
	pop R0
	ret


;R1:R0: data to write to page
;Z: location of page
flash_write:
	push R2

;fill buffer
	ldi R2, 0b00000001 ;enable SPM, buffer storage mode
	out SPMCSR, R2
	spm ;store R1:R0 in temporary buffer

;write buffer to flash
	ldi R2, 0b00000101 ;enable SPM, write mode
	out SPMCSR, R2
	spm ;write the page

;PROBABLY HAVE TO DO SOME WAITING HERE, FIGURE THAT OUT

;return
	pop R2
	ret


;Z: the location of the page to write (assumes SPM buffer is already full)


