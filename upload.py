#CHANGE THIS SO YOU ACTUALLY GET TO CHOOSE THE SERIAL PORT
#MAKE YOUR SLEEP AS SHORT AS POSSIBLE
#TEST THIS WITH CODE THAT WILL HAVE THE LAST BYTE IN ITS OWN CHUNK
    #just need to know what port.send("") does
#STILL GOTTA TEST ALL ERROR HANDLING

import serial
import sys
import os
import time

BAUD_RATE = 38400
BYTES_PER_CHUNK = 15 * 128 #bootloader accepts 15 pages of data at a time



def invalid_write():
    print("ERROR: the bootloader attempted to write to a memory location occupied by itself (are you uploading a program > 32256 bytes?)")
    exit()

def do_nothing():
    pass

BYTE_ACTIONS = {
    b'w': do_nothing, #next word request
    b'd': do_nothing, #done receiving data
    b'o': invalid_write #invalid write error
}



ERROR_BYTE_MAX = bytes([31])

def is_usart_error_byte(byte):
    return byte <= ERROR_BYTE_MAX

def bit_n(byte, n):
    return (byte & (1 << n)) != 0

def parse_usart_error(error_byte):
    error_byte = error_byte[0] #convert to int
    if bit_n(error_byte, 3): #data overrun
        print("ERROR: USART Data OverRun: the bootloader received a new byte while the USART buffer was already full")
    if bit_n(error_byte, 4): #frame error
        print("ERROR: USART Frame Error: the bootloader received one or more invalid start/stop bits")
    exit()



LOAD_BAR_LENGTH = 30
RESTART_LINE = "\x1b[F"

def print_stats(byte_num, total_bytes):
    num_blocks = round(byte_num/total_bytes * LOAD_BAR_LENGTH)
    loading_bar = "#"*num_blocks + " "*(LOAD_BAR_LENGTH - num_blocks) 
    print(f"{RESTART_LINE}[{loading_bar}] {byte_num}/{total_bytes} bytes uploaded")



def chunk_data(data):
    return [
        data[chunk_start: chunk_start + BYTES_PER_CHUNK]
        for chunk_start in range(0, len(data), BYTES_PER_CHUNK)
    ]


def open_port():
    return serial.Serial(
        'COM3', 
        BAUD_RATE, 
        parity = serial.PARITY_SPACE, #USING PARITY AS 9TH BIT (PARITY_SPACE means 0)
        stopbits = serial.STOPBITS_TWO
    )


def upload_chunk(port, chunk, is_last_chunk):
    if is_last_chunk: 
        port.write(chunk[:-1])
        time.sleep(0.1) #HAVE TO WAIT A BIT FOR PREVIOUS WRITE TO FINISH BEFORE CHANGING THE PARITY AGAIN (TERRIBLE RACE CONDITION IN PYSERIAL) (if I change the parity right after writing then it'll use that parity instead of the parity set before writing)
        port.parity = serial.PARITY_MARK #change 9th bit to a 1
        port.write(chunk[-1:])
    else:
        port.write(chunk)
    return port.read(1)


def process_bootloader_response(response):
    if is_usart_error_byte(response):
        parse_usart_error(response)
    else:
        BYTE_ACTIONS[response]()


def windows_start_ansi():
    if sys.platform.startswith('win'): #HAVE TO CLS BEFORE DOING ANY ANSI CONTROL STUFF IN WINDOWS FOR SOME UNGODLY REASON
        os.system('cls')


def upload(data):
    windows_start_ansi()
    port = open_port()
    total_bytes_uploaded = 0
    data_chunks = chunk_data(data)
    print("uploading...\n")

    for chunk_num, chunk in enumerate(data_chunks):
        is_last_chunk = chunk_num == len(data_chunks) - 1
        response = upload_chunk(port, chunk, is_last_chunk)
        total_bytes_uploaded += len(chunk)
        print_stats(total_bytes_uploaded, len(data))
        process_bootloader_response(response)

    print("done uploading")
    port.close()



if __name__ == "__main__":
    if len(sys.argv) >= 2:
        data_file = sys.argv[1]
        try:
            with open(data_file, 'rb') as data:
                data_bytes = data.read()
        except FileNotFoundError:
            print(f"ERROR: can't read provided file ({data_file})")
        else:
            upload(data_bytes)
    else:
        print("ERROR: please provide a program file to upload")