;before uploading the bootloader make sure the following fuses are set:
	;BOOTRST must be *programmed* (set to 0)
		;this fuse determines if the mcu begins exectution in the bootloader section instead of address 0
	;BOOTSZ1 and BOOTSZ0 must be *unprogrammed* (set to 1)
		;these two fuses control WHERE the bootloader section begins in memory
		;setting them both to 1 creates the smallest bootloader space possible on the 328p (256 words)
		;these should already be unprogrammed by default but whatever

;it is recommended to also set up the following lock bits after the bootloader is uploaded to prevent the bootloader from being erased by accident:
	;*program* BLB11 (set to 0) and *unprogram* BLB12 (set to 1)
		;this will make it impossible for any code to write to the bootloader section 


;go to page 277 in atmega datasheet to read about "programming the flash"
;go to page 287 in datasheet for "Assembly Code Example for a Boot Loader"

;flash must be addressed in the Z register using pages and words
;a word is 2 bytes long, there are 64 words per page
;there are 256 pages
;when using Z to address a page, bits 14:7 specify a page and bits 6:1 specifify a word within that page
;   R31     R30
;xppppppp pwwwwwwx 

;you can only write to the flash one page at a time
;first fill the page buffer, then erase the old page, then write the new page.


;future optimizations:
	;CAN PROBABLY ADD THINGS TO THE PAGE BUFFER WHILE A PAGE ERASE IS HAPPENING
	;MIGHT END UP BEING FASTER TO FILL PAGE BUFFER ITSELF INSTEAD OF QUEUE EVEN THOUGH IT WOULD MEAN MORE OS CALLS ON THE UPLOAD SCRIPT SIDE (since you'd only send one page at a time instead of 15)
		;would have to do some tests





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                 definitions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;gpio pins
.EQU BTN_IN_PIN = 1 ;pin that bootloader button is on
.EQU LED_PIN = 0 ;pin that the general purpose LED is on

;USART definitions and transmission bytes
.EQU REQUEST_NEW_DATA = 'w' ;asks sender for next chunk of data
.EQU DONE_BOOTLOADING = 'd' ;tells sender that we've bootloaded the whole program
.EQU ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR = 'o' ;tells sender that the program that is being bootloaded is too long, or the bootloader messed up and tried to overwrite it's own memory
.EQU BAUD_RATE = 38400 ;target baud rate
.EQU OSC_FREQ = 16000000 ;clock rate of mcu
.EQU BAUD_BITS = (OSC_FREQ / BAUD_RATE / 16) - 1 ;the actual bits that must be writted to the baud rate registers
#define USART_SEND_REG R20

;definitions for writing to flash
.EQU PAGE_LENGTH = 64 ;length of a page in words
.EQU ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN = SMALLBOOTSTART * 2 ;bootloader is not allowed to write to this address or beyond (or else it would destroy it's own code), also * 2 because it's specified in bytes instead of words (since that's how we address data when writing it to flash)

#define NEXT_BUFFERED_WORD_ADDR Z ;address to place the next word (address must be in BYTES instead of words)
#define NEXT_BUFFERED_WORD_ADDR_LO R30
#define NEXT_BUFFERED_WORD_ADDR_HI R31

#define TEMP_NEXT_BUFFERED_WORD_ADDR_LO R24 ;using R24 and R25 because they're the only non X/Y/Z registers that can be used with an ADIW instruction
#define TEMP_NEXT_BUFFERED_WORD_ADDR_HI R25 ;these 2 regs are for storing any random values
#define TEMP_NEXT_BUFFERED_WORD_ADDR TEMP_NEXT_BUFFERED_WORD_ADDR_HI: TEMP_NEXT_BUFFERED_WORD_ADDR_LO

#define CURRENT_WORD_LO R0 ;when adding a word to the page buffer we have to address it using R1:R0 
#define CURRENT_WORD_HI R1

#define BUFFER_LOOP_COUNTER R16 ;used to count how many words we have to stick into the temporary page buffer

;queue definitions
.EQU PAGE_LENGTH_BYTES = PAGE_LENGTH * 2
.EQU QUEUE_SIZE_PAGES = 15 ;the size of the queue in pages (the entire ram is actually 16 pages long BUT we need to save some of the ram for the stack)
.EQU QUEUE_SIZE_BYTES = PAGE_LENGTH_BYTES * QUEUE_SIZE_PAGES ;size of the queue in bytes
.EQU QUEUE_START = 0x100 ;sram only actually starts at 0x100, before that is memory mapped stuff
.EQU QUEUE_END = QUEUE_START + QUEUE_SIZE_BYTES ;turns out I dont actually need to use this in the code but... good to keep in mind still

#define QUEUE_HEAD X ;head of circular queue (address in sram to place the next word of data)
#define QUEUE_HEAD_LO R26
#define QUEUE_HEAD_HI R27

#define QUEUE_TAIL Y ;tail of queue (address in sram to find next queued word)
#define QUEUE_TAIL_LO R28
#define QUEUE_TAIL_HI R29

;verification definitions
#define VERIFY_CHECKSUM_LO R22 ;use a BSD checksum to verify that the program was uploaded properly
#define VERIFY_CHECKSUM_HI R23 ;checksum will be 16 bits so it takes 2 registers
#define VERIFY_CHECKSUM VERIFY_CHECKSUM_HI: VERIFY_CHECKSUM_LO

;other register definitions
#define DONE_RECEIVING_DATA R18 ;stores a 1 if we're done receiving data, 0 otherwise
#define TEMP_REG R21 ;used for storing values that will be used very soon, ie in an instruction or 2. I should always be able to easily know if this register is available or not just by glancing at nearby instructions



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                   macros
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: word: word to find lo byte of
;return: lo byte of arg 1
#define lo_byte(word) (word & 0xFF)

;args: word: word to find hi byte of
;return: hi byte of input
#define hi_byte(word) (word >> 8)


;waits for an spm instruction to finish executing
.MACRO wait_spm
check_if_spm_done:
	in TEMP_REG, SPMCSR ;load spm status reg
	sbrc TEMP_REG, 0 ;check if spm is still going, skip next instruction if it's not
	rjmp check_if_spm_done ;keep waiting for spm to finish
.ENDMACRO


;waits until there is a byte to be read from the usart
.MACRO wait_for_usart_byte
check_usart:
	lds TEMP_REG, UCSR0A ;grab status reg
	sbrs TEMP_REG, 7 ;see if there is some unread data in USART
	rjmp check_usart ;if theres no unread data then keep waiting
.ENDMACRO



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                pre-bootloader
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.ORG 0 ;throw in a tiny program as placeholder application code

application_code: ;if we exit the bootloader without uploading anything then this will make us spin instead of executing 32k NOPs and restarting the bootloader
	rjmp application_code


.ORG SMALLBOOTSTART ;place the bootloader at the beginning of the smallest bootloader section (256 words large)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                initialization
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;disable all interrupts so currently bootloaded program can't interrupt bootloading process
	cli

;check if we're loading a program
	cbi DDRB, BTN_IN_PIN ;set the proper pin as input (should be default behavior anyway)
	nop ;must wait one clock cycle for input register to update after setting pins as input
	sbis PINB, BTN_IN_PIN ;if pin is high (button is pressed) then enter the bootloader
	rjmp exit_bootloader ;exit bootloader if button is not pressed

;turn on LED to indicate we're in the bootloader
	sbi DDRB, LED_PIN ;set LED_PIN as output
	sbi PORTB, LED_PIN ;turn LED on

;set up variables for program loading
	clr NEXT_BUFFERED_WORD_ADDR_HI ;start buffering words at address 0
	clr NEXT_BUFFERED_WORD_ADDR_LO 
	clr DONE_RECEIVING_DATA ;not done receiving data

;init USART
	ldi TEMP_REG, hi_byte(BAUD_BITS)
	sts UBRR0H, TEMP_REG ;init baud rate hi
	ldi TEMP_REG, lo_byte(BAUD_BITS)
	sts UBRR0L, TEMP_REG ;init baud rate lo
	ldi TEMP_REG, 0b00011100 ;turn on both receiver and transmitter, also use 9 bit communication
	sts UCSR0B, TEMP_REG ;save USART setting
	ldi TEMP_REG, 0b00001110 ;9 bit communication mode, 2 stop bits, no parity bit, async USART mode
	sts UCSR0C, TEMP_REG



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                receive data
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

receive_data:

;let upload script know we're ready to receive more data
	ldi USART_SEND_REG, REQUEST_NEW_DATA
	rcall send_byte

;reset queue to start
	ldi QUEUE_HEAD_LO, lo_byte(QUEUE_START)
	ldi QUEUE_HEAD_HI, hi_byte(QUEUE_START) ;queue doesn't start at 0 because memory mapped registers

fill_queue:

;wait for a new byte to arrive
	wait_for_usart_byte

;make sure there were no errors
	lds USART_SEND_REG, UCSR0A ;load status into USART_SEND_REG so I can send an error asap 
	andi USART_SEND_REG, 0b00011100 ;mask out all bits except errors
	breq read_received_data ;if theres no error we can just read the data 

;throw an error if we have any error bits
	rjmp error ;couldn't just do a brne last instruction because brne can only travel +-64 instructions

read_received_data:
	lds TEMP_REG, UCSR0B ;grab status reg that contains 9th bit of data
	sbrc TEMP_REG, 1 ;check if bit 9 of data is a 1
	ldi DONE_RECEIVING_DATA, 1 ;if bit 9 of data was a 1, record it
	lds TEMP_REG, UDR0 ;read byte from USART
	st QUEUE_HEAD+, TEMP_REG ;store received byte in queue and move the head forward

;stop receiving if we got the last byte
	cpi DONE_RECEIVING_DATA, 1
	breq process_received_data ;process data when flag indicates that theres no more data coming

;keep receiving data while the queue isn't full
	cpi QUEUE_HEAD_LO, lo_byte(QUEUE_END) ;start 16 bit compare with QUEUE_HEAD and QUEUE_SIZE
	ldi TEMP_REG, hi_byte(QUEUE_END) ;load hi byte into temp reg because I cant do a cpc with an immediate
	cpc QUEUE_HEAD_HI, TEMP_REG ;finish comparing
	brlo fill_queue ;queue isnt full if QUEUE_HEAD < QUEUE_SIZE



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               fill the page buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

process_received_data:

;reset position we're reading queue from
	ldi QUEUE_TAIL_LO, lo_byte(QUEUE_START)
	ldi QUEUE_TAIL_HI, hi_byte(QUEUE_START) ;queue doesn't start at 0 because memory mapped registers

buffer_next_page:

;reset loop counter
	ldi BUFFER_LOOP_COUNTER, PAGE_LENGTH ;going to buffer 64 words

buffer_next_word:

;load data needed to buffer the next word
	ld CURRENT_WORD_LO, QUEUE_TAIL+ ;dequeue first byte and move tail forward
	ld CURRENT_WORD_HI, QUEUE_TAIL+ ;dequeue 2nd byte (LO COMES BEFORE HI BECAUSE COMPILED BINARIES (AS WELL AS THE FLASH ITSELF) STORES WORDS IN LITTLE ENDIAN FORMAT, ALSO FOR SOME REASON SPM EXPECTS YOU TO PROVIDE WORDS IN R1:R0 IN BIG ENDIAN FORM)

;add word to page buffer
	in TEMP_REG, SPMCSR ;get spm reg
	sbr TEMP_REG, 0b00000001 ;set bit 0 
	out SPMCSR, TEMP_REG ;enable SPM, page buffer fill mode
	spm ;add word to temporary page buffer

;update byte counts
	adiw NEXT_BUFFERED_WORD_ADDR, 2 ;increase by two because spm wants bit 0 of Z to always be 0 for some reason (so the word count is offset by 1 bit... you can think of this as just counting bytes instead of words)
	subi BUFFER_LOOP_COUNTER, 1 

;check if we've buffered everything in the queue
	cp QUEUE_TAIL_LO, QUEUE_HEAD_LO ;16 bit compare of QUEUE_TAIL and QUEUE_HEAD
	cpc QUEUE_TAIL_HI, QUEUE_HEAD_HI
	brsh buffered_whole_queue ;if QUEUE_TAIL >= QUEUE_HEAD then we've buffered the whole queue (or more)

;keep looping if we haven't buffered a whole page
	cpi BUFFER_LOOP_COUNTER, 0 ;check if we're done looping over the page
	brne buffer_next_word ;keep looping if BUFFER_LOOP_COUNTER isn't 0 yet
	rjmp write_page ;write the page if it's been buffered

buffered_whole_queue:

;if we've just buffered everything in the queue then we can write the page
	breq write_page

;if we've buffered one more byte than the queue contains, we need to adjust NEXT_BUFFERED_WORD_ADDR to reflect that
	sbiw NEXT_BUFFERED_WORD_ADDR, 1 ;this can happen because we buffer one word at a time (however the reason I have to adjust NEXT_BUFFERED_WORD_ADDR is so verification doesn't loop over anything that's not part of the program)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                   write page
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

write_page:

;prepare NEXT_BUFFERED_WORD_ADDR for erase and write operations
	movw TEMP_NEXT_BUFFERED_WORD_ADDR_LO, NEXT_BUFFERED_WORD_ADDR_LO ;save NEXT_BUFFERED_WORD_ADDR so it can be restored later (movw makes you specify only lo registers)
	sbiw NEXT_BUFFERED_WORD_ADDR, 1 ;wanna lower NEXT_BUFFERED_WORD_ADDR back to the last multiple of 64, have to sub 1 because if we buffered a whole page then NEXT_BUFFERED_WORD_ADDR is already pointing to the 0th word of the NEXT page (this will always work because we always buffer at least one word)
	andi NEXT_BUFFERED_WORD_ADDR_LO, 0b11000000 ;and lo byte with a bit mask to round back to last 64 bits

;check if we're trying to overwrite the bootloader itself
	ldi TEMP_REG, lo_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cp NEXT_BUFFERED_WORD_ADDR_LO, TEMP_REG ;compare NEXT_BUFFERED_WORD_ADDR and ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	ldi TEMP_REG, hi_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cpc NEXT_BUFFERED_WORD_ADDR_HI, TEMP_REG
	brlo erase_current_page ;if NEXT_BUFFERED_WORD_ADDR < ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN then we can erase the page
	
;we're trying to overwrite the bootloader, so throw an error
	ldi USART_SEND_REG, ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR ;prepare error byte for sending
	rjmp error ;then throw the error (couldn't just brsh because error brance is too far away)

erase_current_page:
	ldi TEMP_REG, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, TEMP_REG
	spm ;erase the page
	wait_spm ;wait for erase to finish

;write the current page indicated by NEXT_BUFFERED_WORD_ADDR
	ldi TEMP_REG, 0b00000101 ;enable SPM, write mode
	out SPMCSR, TEMP_REG
	spm ;write the page
	wait_spm ;wait for write to finish

;restore NEXT_BUFFERED_WORD_ADDR to the proper value (can't just add 64 because we're gonna use this value to keep track of how much program memory to send back to upload script later)
	movw NEXT_BUFFERED_WORD_ADDR_LO, TEMP_NEXT_BUFFERED_WORD_ADDR_LO ;(movw makes you specify only lo registers)

;if we haven't written all the pages in the queue, keep writing
	cp QUEUE_TAIL_LO, QUEUE_HEAD_LO ;16 bit compare of QUEUE_TAIL and QUEUE_HEAD
	cpc QUEUE_TAIL_HI, QUEUE_HEAD_HI
	brlo buffer_next_page ;if QUEUE_TAIL < QUEUE_HEAD then keep buffering

;if we haven't got all the data yet, receive some more
	sbrs DONE_RECEIVING_DATA, 0 ;using sbrs instead of cpi because receive_data is too far away for a branch instruction
	rjmp receive_data

;else, we're done writing all the data (all pages have been written and no more data is coming)
	ldi USART_SEND_REG, DONE_BOOTLOADING ;tell upload script that the whole program has been bootloaded
	rcall send_byte



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                 verify program
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;enable reading/execution of application code
	ldi TEMP_REG, 0b00010001 ;running this spm instruction reenables the RWW (read while write) section of the flash memory
	out SPMCSR, TEMP_REG ;need to reenable the RWW section because it gets disabled automatically whenever you do any writing or erasing to that section
	spm
	wait_spm ;have to wait for spm to finish (despite the datasheet not mentioning having to wait on this spm command at all)

;prepare to send checksum of bootloaded program back
	movw VERIFY_CHECKSUM_LO, NEXT_BUFFERED_WORD_ADDR_LO ;initialize checksum to be the number of bytes bootloaded (don't init checksum as 0 because then all programs consisting of only NOPs will have the same checksum)
	sbiw NEXT_BUFFERED_WORD_ADDR, 1 ;NEXT_BUFFERED_WORD_ADDR points to the next byte, so we have to decrement to get the previous byte (the last bootloaded byte)

verify_byte:

;rotate checksum (a la BSD checksum)
	lsr VERIFY_CHECKSUM_HI ;rotate hi byte of hash right and shift lsb into carry flag
	ror VERIFY_CHECKSUM_LO ;rotate lo byte of hash right, shifting in the carry flag (lsb of VERIFY_HASH_HI) and shifting the lsb of VERIFY_HASH_LO into carry
	brcc add_byte_to_checksum ;we're done rotating if a 0 was rotated out of VERIFY_CHECKSUM_LO
	sbr VERIFY_CHECKSUM_HI, 0b10000000 ;set first msb of checksum if 1 got shifted out of VERIFY_CHECKSUM_LO

add_byte_to_checksum:
	lpm TEMP_REG, NEXT_BUFFERED_WORD_ADDR ;load program byte 
	add VERIFY_CHECKSUM_LO, TEMP_REG ;add program byte to checksum
	clr TEMP_REG ;clear TEMP_REG because theres no add immediate with carry
	adc VERIFY_CHECKSUM_HI, TEMP_REG ;propagate carry into hi byte of checksum

;keep adding bytes to checksum until we're done the whole program
	sbiw NEXT_BUFFERED_WORD_ADDR, 1 ;address of next byte to send
	brcc verify_byte ;keep looping until NEXT_BUFFERED_WORD_ADDR underflows

;send checksum to upload script
	mov USART_SEND_REG, VERIFY_CHECKSUM_HI ;send hi byte of checksum
	rcall send_byte
	mov USART_SEND_REG, VERIFY_CHECKSUM_LO ;send lo byte of checksum
	rcall send_byte

;wait for verification success from upload script
	wait_for_usart_byte ;this way the application program doesn't start right away if it wasn't bootloaded properly, AND we make sure that all usart data has been transmitted (theres a bit that you should be able to check to make sure of that but data still somehow manages to get messed up when you reset all the usart registers right afterwards)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                 reset registers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;reset gpio registers
	clr TEMP_REG ;next two registers should be reset to 0
	out PORTB, TEMP_REG ;reset port b but also turn off LED to indicate we're no longer in the bootloader
	out DDRB, TEMP_REG ;all port b pins are inputs by default

;reset usart registers
	clr TEMP_REG ;next three registers should be reset to 0
	sts UCSR0B, TEMP_REG ;clear status reg B
	sts UBRR0L, TEMP_REG ;clear baud rate
	sts UBRR0H, TEMP_REG
	ldi TEMP_REG, 0b00000110 ;default behaviour is async, no parity, 1 stop bit, 8 data bits
	sts UCSR0C, TEMP_REG ;set status reg C to default
	ldi TEMP_REG, 0b00100000 ;default behaviour is no multiprocessor comm mode, 1x usart transmission speed
	sts UCSR0A, TEMP_REG ;set status reg A to default



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                exit bootloader
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

exit_bootloader: ;clean exit
	jmp 0 ;start uploaded program


error: ;reports the byte in USART_SEND_REG back to sender then spins forever
	rcall send_byte
panic_forever: ;infinite loop
	rjmp panic_forever





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: USART_SEND_REG: byte to transmit
send_byte:

wait_for_empty_transmit_buffer:
	lds TEMP_REG, UCSR0A ;can't use sbis on all IO ports, so I have to fill the temp register and do sbrs
	sbrs TEMP_REG, 5 ;check if transmit data register is empty
	rjmp wait_for_empty_transmit_buffer ;if full, keep waiting

;clear 9th bit
	lds TEMP_REG, UCSR0B ;can't use cbi on this IO register
	cbr TEMP_REG, 0b00000001 ;always set 9th bit to 0, it's only used when receiving data (cbr clears the specified bits)
	sts UCSR0B, TEMP_REG ;update 9th bit

;send data
	sts UDR0, USART_SEND_REG ;again, can't use OUT instruction because usart registers are above 0x3f

;return
	ret



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               plug my github
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.ORG FLASHEND - 7 ;put this right at the end of the whole flash (.ORG addresses words, not bytes)
.DB "github: @ehrenjn" 