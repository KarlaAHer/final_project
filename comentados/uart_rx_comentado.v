//====================================================================
// uart_rx.v  (VERSION COMENTADA LINEA POR LINEA)
//
// QUE ES:   El receptor UART. Escucha el pin UART_RX y convierte los
//           bits que llegan uno por uno en un byte completo (8 bits).
// DE DONDE: El pin fisico UART_RX de la DE10-Lite, conectado al TX del
//           FT232RL (o HC-05). Por ahi llega lo que manda MATLAB.
// A DONDE:  data_out y data_ready van a line_rx (en braille_top se
//           llaman rx_byte y rx_ready).
// FORMATO:  9600 baudios, 8N1 = 1 bit START (0) + 8 bits de datos
//           (primero el LSB) + 1 bit STOP (1). Total: 10 bits por byte.
//====================================================================

module uart_rx (                 // Declara el modulo. "uart_rx" es el nombre con el que
                                 // braille_top lo instancia: uart_rx RX0 (...)

    input  wire       clk,       // Reloj de 50 MHz (CLOCK_50). Todo el modulo avanza
                                 // en sus flancos de subida, uno cada 20 ns.

    input  wire       rst,       // Reset activo en alto. Viene de braille_top como
                                 // rst = ~KEY[0]: al presionar KEY[0] vale 1 y todo
                                 // vuelve a su estado inicial.

    input  wire       rx,        // El cable serial. Viene directo del pin UART_RX.
                                 // En reposo vale 1. Cuando baja a 0, empieza un byte.

    output reg  [7:0] data_out,  // El byte ya armado (8 bits = 1 caracter).
                                 // Es "reg" porque se asigna dentro de un always y
                                 // debe GUARDAR su valor hasta que llegue otro byte.
                                 // Destino: line_rx.rx_data

    output reg        data_ready // Pulso de 1 ciclo (20 ns) que dice "data_out es nuevo".
                                 // Es un pulso, no un nivel, para que line_rx cuente
                                 // cada letra UNA sola vez.
                                 // Destino: line_rx.rx_valid
);

    //====================================================
    // PARAMETROS
    //====================================================

    parameter CLKS_PER_BIT = 5208;   // Cuantos ciclos de reloj dura UN bit.
                                     // 50 000 000 / 9600 = 5208.33 -> 5208.
                                     // Es "parameter" para que braille_top pueda
                                     // cambiarlo sin tocar este archivo:
                                     //   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) RX0
                                     // Si quisieras 115200 baudios: 50e6/115200 = 434.


    //====================================================
    // ESTADOS
    //====================================================
    // La recepcion es una maquina de estados (FSM) de 4 pasos.
    // localparam = constante interna, no se puede cambiar desde fuera.
    // Se les da nombre para que el codigo se lea "IDLE" y no "2'b00".

    localparam IDLE  = 2'b00;    // Reposo: esperando que la linea baje a 0.
    localparam START = 2'b01;    // Se detecto la bajada; se confirma que sea un START real.
    localparam DATA  = 2'b10;    // Leyendo los 8 bits de datos.
    localparam STOP  = 2'b11;    // Revisando el bit de STOP (debe ser 1).

    reg [1:0] state;             // Estado actual. 2 bits porque hay 4 estados (2^2 = 4).


    //====================================================
    // REGISTROS INTERNOS
    //====================================================

    reg [12:0] clk_count;        // Cuenta ciclos dentro de un bit (0 .. 5207).
                                 // 13 bits porque 2^13 = 8192 >= 5208.
                                 // Con 12 bits (4096) no alcanzaria.

    reg [2:0]  bit_index;        // Que bit de datos se esta leyendo (0 .. 7).
                                 // 3 bits = 8 valores, justo los 8 bits de un byte.

    reg [7:0]  rx_data;          // Aqui se va ARMANDO el byte, bit por bit.
                                 // Solo cuando el byte esta completo y el STOP es
                                 // correcto se copia a data_out. Asi data_out nunca
                                 // muestra un byte a medias.


    //====================================================
    // SINCRONIZACION DE RX
    //====================================================
    // PROBLEMA: la senal rx viene de la PC, que NO usa el reloj de la FPGA.
    // Puede cambiar justo en el flanco del reloj y dejar al flip-flop
    // "indeciso" entre 0 y 1 (eso se llama metaestabilidad).
    // SOLUCION: pasarla por 2 flip-flops seguidos. Al segundo ya llega estable.
    // Por eso el resto del modulo usa rx_sync_2 y NUNCA rx directamente.

    reg rx_sync_1;               // Primer flip-flop: puede quedar inestable un momento.
    reg rx_sync_2;               // Segundo flip-flop: ya estable. Es la senal "limpia".

    always @(posedge clk or posedge rst) begin   // Se ejecuta en cada flanco de subida del
                                                 // reloj, o de inmediato si rst sube
                                                 // (reset asincrono).

        if (rst) begin                           // Durante el reset...

            rx_sync_1 <= 1'b1;                   // ...se inicializan en 1, porque 1 es el
            rx_sync_2 <= 1'b1;                   // valor de reposo de la linea UART. Si
                                                 // fueran 0, la FSM creeria que llego un
                                                 // START al soltar el reset.

        end
        else begin                               // Funcionamiento normal:

            rx_sync_1 <= rx;                     // 1er flip-flop copia el pin.
            rx_sync_2 <= rx_sync_1;              // 2do flip-flop copia al 1ro.
                                                 // Resultado: rx_sync_2 = rx con 2 ciclos
                                                 // (40 ns) de retraso, pero estable.
                                                 // 40 ns es nada frente a 104 us por bit.

        end

    end


    //====================================================
    // MAQUINA DE ESTADOS UART RX
    //====================================================

    always @(posedge clk or posedge rst) begin   // Otra vez: en cada flanco de reloj o reset.

        if (rst) begin                           // RESET: todo a su valor inicial.

            state      <= IDLE;                  // Empieza esperando.

            clk_count  <= 13'd0;                 // Contadores en cero.
            bit_index  <= 3'd0;

            rx_data    <= 8'd0;                  // Byte en construccion vacio.
            data_out   <= 8'd0;                  // Salida en cero.

            data_ready <= 1'b0;                  // Sin aviso de byte nuevo.

        end
        else begin                               // FUNCIONAMIENTO NORMAL

            // Se activa solamente un ciclo
            data_ready <= 1'b0;                  // "Valor por defecto": en cada ciclo se baja
                                                 // a 0. Solo en STOP se sube a 1. Como en
                                                 // el siguiente ciclo esta linea lo vuelve a
                                                 // bajar, data_ready dura exactamente 1 ciclo.
                                                 // Asi se fabrica un PULSO.


            case (state)                         // Segun el estado actual, hace una cosa u otra.

                //========================================
                // IDLE: esperando que empiece un byte
                //========================================

                IDLE: begin

                    clk_count <= 13'd0;          // Mantiene contadores en cero para empezar
                    bit_index <= 3'd0;           // limpio cuando llegue el START.

                    // UART esta normalmente en 1.
                    // Si baja a 0 comienza START.

                    if (rx_sync_2 == 1'b0) begin // La linea bajo a 0: posible bit de START.

                        state <= START;          // Pasa a confirmarlo.

                    end

                end


                //========================================
                // START: confirmar que el START es real
                //========================================

                START: begin

                    // Verificar el bit START
                    // aproximadamente en su centro.

                    if (clk_count == (CLKS_PER_BIT / 2) - 1) begin
                                                 // Espera MEDIO bit: 5208/2 - 1 = 2603
                                                 // (cuenta de 0 a 2603 = 2604 ciclos, 52 us).
                                                 // POR QUE MEDIO: asi queda parado justo en el
                                                 // centro del bit START. De aqui en adelante,
                                                 // saltando de 5208 en 5208, cada lectura cae
                                                 // en el CENTRO de cada bit, donde la senal
                                                 // es mas estable (lejos de los cambios).

                        clk_count <= 13'd0;      // Reinicia el contador para medir el siguiente bit.

                        if (rx_sync_2 == 1'b0) begin   // A la mitad del bit, sigue en 0:

                            state <= DATA;       // START confirmado. A leer datos.

                        end
                        else begin               // Ya volvio a 1: fue solo un pico de ruido.

                            // Falso START
                            state <= IDLE;       // Se ignora y vuelve a esperar.

                        end

                    end
                    else begin                   // Todavia no llega a la mitad del bit:

                        clk_count <= clk_count + 1'b1;   // sigue contando ciclos.

                    end

                end


                //========================================
                // DATA: leer los 8 bits
                //========================================

                DATA: begin

                    if (clk_count == CLKS_PER_BIT - 1) begin
                                                 // Paso UN bit completo (5208 ciclos) desde la
                                                 // ultima lectura: estamos en el centro del
                                                 // siguiente bit.

                        clk_count <= 13'd0;      // Reinicia para medir el siguiente bit.

                        // UART transmite LSB primero
                        rx_data[bit_index] <= rx_sync_2;
                                                 // Guarda el bit leido en la posicion bit_index.
                                                 // El 1er bit que llega es el bit 0 (LSB), por
                                                 // eso bit_index empieza en 0 y va subiendo.
                                                 // Ejemplo 'R' = 0x52 = 0101_0010:
                                                 //   llegan 0,1,0,0,1,0,1,0 -> rx_data[0..7]


                        if (bit_index == 3'd7) begin   // Si ese era el bit 7 (el ultimo)...

                            bit_index <= 3'd0;   // ...reinicia el indice para el siguiente byte
                            state     <= STOP;   // ...y pasa a revisar el bit de STOP.

                        end
                        else begin               // Si faltan bits:

                            bit_index <= bit_index + 1'b1;   // avanza al siguiente bit.

                        end

                    end
                    else begin                   // Aun no pasa un bit completo:

                        clk_count <= clk_count + 1'b1;   // sigue contando.

                    end

                end


                //========================================
                // STOP: revisar que el byte termine bien
                //========================================

                STOP: begin

                    if (clk_count == CLKS_PER_BIT - 1) begin
                                                 // Esperamos un bit mas: centro del bit STOP.

                        clk_count <= 13'd0;      // Reinicia contador.

                        // STOP debe ser 1
                        if (rx_sync_2 == 1'b1) begin   // STOP correcto: el byte es valido.

                            data_out   <= rx_data;     // Copia el byte armado a la salida.
                                                       // -> line_rx lo recibe como rx_data.
                            data_ready <= 1'b1;        // Pulso "llego un byte nuevo".
                                                       // -> line_rx lo recibe como rx_valid.
                                                       // En el siguiente ciclo la linea de
                                                       // "valor por defecto" lo regresa a 0.

                        end
                        // Si el STOP vale 0 (error de trama, ruido, baudios mal
                        // configurados), NO se entrega nada: el byte se descarta.
                        // Es mejor perder un byte que pasar uno incorrecto.

                        state <= IDLE;           // En ambos casos vuelve a esperar otro byte.

                    end
                    else begin

                        clk_count <= clk_count + 1'b1;   // Aun no llega al centro del STOP.

                    end

                end


                //========================================
                // DEFAULT: seguridad
                //========================================

                default: begin
                                                 // Con 2 bits y 4 estados todos estan cubiertos,
                                                 // pero si por un error electrico "state" tuviera
                                                 // un valor raro, regresa a IDLE en vez de
                                                 // quedarse trabado. Es buena practica siempre.

                    state <= IDLE;

                end

            endcase

        end

    end

endmodule                                        // Fin del modulo.

//====================================================================
// RESUMEN DEL TIEMPO DE UN BYTE (a 9600 baudios):
//   IDLE  -> detecta la bajada a 0
//   START -> espera 2604 ciclos (medio bit) y confirma el 0
//   DATA  -> 8 lecturas, una cada 5208 ciclos (centro de cada bit)
//   STOP  -> 1 lectura mas a los 5208 ciclos; si es 1 entrega el byte
//   Total: ~9.5 bits (~0.99 ms). El ultimo medio bit del STOP se pasa
//   en IDLE, listo para el siguiente START.
//====================================================================
