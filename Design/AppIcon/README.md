# Icono de HAVIT

## Fuente

Archivo Figma: https://www.figma.com/design/3bmX64I7Rt85DV3boqOlsc/Havit-Device-UI?node-id=504-125

- Fondo: nodo 504:125, #0f0f0f, lienzo de diseño 256 × 256.
- Símbolo: grupo 504:138, centrado en el lienzo.
- Capas SVG originales: Layers/left.svg (504:134) y Layers/right.svg (504:133). Las exportaciones conservan las sombras del diseño.
- Figma-export.png: referencia exportada del diseño, con la máscara y el fondo del lienzo de Figma. No se empaqueta como icono.
- ../../Assets/AppIcon.png: arte cuadrado y opaco de 1024 × 1024 para la instalación. El sistema aplica la máscara de las esquinas.

## Vista previa con vidrio en Figma

Se añadió una variante independiente con el efecto GLASS de Figma en el nodo 519:2:
https://www.figma.com/design/3bmX64I7Rt85DV3boqOlsc/Havit-Device-UI?node-id=519-2

Las dos barras conservan la geometría original y usan un relleno translúcido, borde de luz y el efecto GLASS. Glass-preview.png es una captura de esa variante para revisión; no se utiliza como recurso dentro de la app. El diseño original permanece disponible.

## Integración actual

xtool.yml configura iconPath: Assets/AppIcon.png. La versión de xtool utilizada acepta PNG para este campo; no admite paquetes .icon. El icono instalado conserva el aspecto del diseño de Figma con su halo blanco. Es una imagen estática, sin refracción ni reflejos dinámicos de Liquid Glass.

## Preparación para Liquid Glass nativo

Las capas originales están separadas para poder importarlas en Icon Composer cuando se disponga de un entorno macOS compatible. Crear un lienzo 1024 × 1024, definir el fondo #0f0f0f y mantener el símbolo centrado a la escala del diseño (ancho total 505.565 px y alto 408 px). Para una nueva exportación específica para Icon Composer, separar las sombras dibujadas del símbolo para evitar duplicar sus efectos con los del material nativo. Configurar el material, revisar las apariencias y exportar el archivo .icon. Después compilarlo con las herramientas de Apple e integrarlo en el empaquetado de la app.

No se ha creado un archivo .icon ni se ha validado el efecto dinámico en iOS desde este entorno Windows/WSL.

Referencia oficial: https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer